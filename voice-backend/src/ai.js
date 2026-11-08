'use strict';

const express = require('express');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const MAX_AUDIO_BYTES = 23 * 1024 * 1024;
const MIME_BY_EXTENSION = {
  '.mp3': 'audio/mpeg',
  '.mp4': 'audio/mp4',
  '.mpeg': 'audio/mpeg',
  '.mpga': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.wav': 'audio/wav',
  '.webm': 'audio/webm',
};

const SUMMARY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    title: { type: 'string' },
    summary: { type: 'string' },
    key_points: { type: 'array', items: { type: 'string' } },
    decisions: { type: 'array', items: { type: 'string' } },
    tasks: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          task: { type: 'string' },
          owner: { type: ['string', 'null'] },
          due_date: { type: ['string', 'null'] },
        },
        required: ['task', 'owner', 'due_date'],
      },
    },
    open_questions: { type: 'array', items: { type: 'string' } },
  },
  required: ['title', 'summary', 'key_points', 'decisions', 'tasks', 'open_questions'],
};

function sanitizeFileName(value) {
  let raw = String(value || 'recording').replace(/\\/g, '/');
  raw = path.posix.basename(raw);
  const extension = path.extname(raw).toLowerCase();
  const stem = path.posix.basename(raw, path.posix.extname(raw))
    .normalize('NFKC')
    .replace(/[^\p{L}\p{N}._-]+/gu, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80) || 'recording';
  return stem + extension;
}

function audioMimeType(fileName) {
  return MIME_BY_EXTENSION[path.extname(fileName).toLowerCase()] || null;
}

function normalizeTranscription(payload) {
  const sourceSegments = Array.isArray(payload?.segments) ? payload.segments : [];
  const segments = sourceSegments.map((segment) => ({
    start: Number.isFinite(Number(segment.start)) ? Number(segment.start) : null,
    end: Number.isFinite(Number(segment.end)) ? Number(segment.end) : null,
    speaker: typeof segment.speaker === 'string' ? segment.speaker : null,
    text: typeof segment.text === 'string' ? segment.text.trim() : '',
  })).filter((segment) => segment.text);

  const text = typeof payload?.text === 'string' && payload.text.trim()
    ? payload.text.trim()
    : segments.map((segment) => (segment.speaker ? segment.speaker + ': ' : '') + segment.text).join('\n');

  if (!text) throw new Error('Сервис распознавания вернул пустую расшифровку.');
  return { text, segments };
}

function extractOutputText(response) {
  if (typeof response?.output_text === 'string') return response.output_text;
  const parts = [];
  for (const item of response?.output || []) {
    if (item?.type !== 'message' || !Array.isArray(item.content)) continue;
    for (const part of item.content) {
      if (part?.type === 'output_text' && typeof part.text === 'string') parts.push(part.text);
    }
  }
  return parts.join('\n').trim();
}

async function readOpenAIResponse(response) {
  const raw = await response.text();
  let data;
  try { data = raw ? JSON.parse(raw) : {}; } catch { data = {}; }
  if (!response.ok) {
    const message = data?.error?.message || data?.message || ('OpenAI API вернул HTTP ' + response.status);
    const error = new Error(message);
    error.status = response.status === 429 ? 503 : 502;
    throw error;
  }
  return data;
}

function transcriptionRequestOptions(model) {
  if (model === 'gpt-4o-transcribe-diarize') {
    return { responseFormat: 'diarized_json', chunkingStrategy: 'auto' };
  }
  return { responseFormat: 'json', chunkingStrategy: null };
}

async function transcribeAudio(buffer, fileName, mimeType) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    const error = new Error('На сервере не задан OPENAI_API_KEY.');
    error.status = 503;
    throw error;
  }

  const form = new FormData();
  const blob = new Blob([Uint8Array.from(buffer)], { type: mimeType });
  form.append('file', blob, fileName);
  const model = process.env.OPENAI_TRANSCRIPTION_MODEL || 'gpt-4o-transcribe-diarize';
  const options = transcriptionRequestOptions(model);
  form.append('model', model);
  form.append('response_format', options.responseFormat);
  if (options.chunkingStrategy) form.append('chunking_strategy', options.chunkingStrategy);

  const response = await fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + apiKey },
    body: form,
    signal: AbortSignal.timeout(10 * 60 * 1000),
  });
  return normalizeTranscription(await readOpenAIResponse(response));
}

async function summarizeTranscript(transcription) {
  const apiKey = process.env.OPENAI_API_KEY;
  const response = await fetch('https://api.openai.com/v1/responses', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + apiKey,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: process.env.OPENAI_SUMMARY_MODEL || 'gpt-5.6',
      store: false,
      max_output_tokens: 1800,
      instructions: [
        'Ты — ассистент для анализа встреч и аудиозаписей. Пиши на русском языке.',
        'Составь точный конспект только по переданному тексту. Не выдумывай участников, решения, сроки и поручения.',
        'Если ответственный или срок не названы явно, укажи null. Не превращай предположения в факты.',
        'В title дай короткое название встречи. В summary — связное краткое содержание.',
        'В key_points — основные тезисы. В decisions — только явно принятые решения.',
        'В tasks — конкретные поручения и действия. В open_questions — вопросы, которые остались нерешёнными.',
        'Если разделу нечего добавить, верни пустой массив.',
      ].join(' '),
      input: [
        {
          role: 'user',
          content: 'Подготовь конспект и задачи по расшифровке ниже. Сохрани метки спикеров, если они присутствуют.\n\n' + transcription.text,
        },
      ],
      text: {
        format: {
          type: 'json_schema',
          name: 'golos_meeting_summary',
          strict: true,
          schema: SUMMARY_SCHEMA,
        },
      },
    }),
    signal: AbortSignal.timeout(3 * 60 * 1000),
  });

  const data = await readOpenAIResponse(response);
  const output = extractOutputText(data);
  if (!output) throw new Error('Модель не вернула конспект.');
  try {
    return JSON.parse(output);
  } catch {
    throw new Error('Модель вернула некорректный формат конспекта.');
  }
}

function createAIRouter({ dataDir }) {
  const router = express.Router();
  const recordsDir = path.join(dataDir, 'ai-recordings');

  async function readRecord(id) {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
    try {
      return JSON.parse(await fs.promises.readFile(path.join(recordsDir, id + '.json'), 'utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') return null;
      throw error;
    }
  }

  router.post(
    '/recordings',
    express.raw({ type: ['audio/*', 'application/octet-stream', 'video/mp4'], limit: MAX_AUDIO_BYTES }),
    async (req, res) => {
      let audioPath;
      let metadataPath;
      try {
        if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
          return res.status(400).json({ error: 'Передайте аудиофайл в теле запроса.' });
        }
        if (req.body.length > MAX_AUDIO_BYTES) {
          return res.status(413).json({ error: 'Файл больше 24 МБ. Сожмите аудио или разделите запись на части.' });
        }
        const suppliedName = req.get('x-file-name') || 'recording.m4a';
        let decodedName = suppliedName;
        try { decodedName = decodeURIComponent(suppliedName); } catch { /* use the supplied name */ }
        const fileName = sanitizeFileName(decodedName);
        const mimeType = audioMimeType(fileName);
        if (!mimeType) {
          return res.status(415).json({ error: 'Формат не поддерживается. Используйте MP3, MP4, M4A, MPEG, MPGA, WAV или WEBM.' });
        }
        if (!process.env.OPENAI_API_KEY) {
          return res.status(503).json({ error: 'AI-обработка не настроена: на сервере отсутствует OPENAI_API_KEY.' });
        }

        const audioBuffer = Buffer.from(req.body);
        const transcription = await transcribeAudio(audioBuffer, fileName, mimeType);
        let summary = null;
        let summaryWarning = null;
        try {
          summary = await summarizeTranscript(transcription);
        } catch (error) {
          summaryWarning = error.message || 'Не удалось подготовить конспект.';
        }

        await fs.promises.mkdir(recordsDir, { recursive: true, mode: 0o700 });
        const id = crypto.randomUUID();
        const extension = path.extname(fileName).toLowerCase();
        audioPath = path.join(recordsDir, id + extension);
        metadataPath = path.join(recordsDir, id + '.json');
        const record = {
          id,
          fileName,
          createdAt: new Date().toISOString(),
          fileSize: audioBuffer.length,
          audioFile: id + extension,
          transcript: transcription.text,
          segments: transcription.segments,
          summary,
          summaryWarning,
        };
        await fs.promises.writeFile(audioPath, audioBuffer, { mode: 0o600, flag: 'wx' });
        await fs.promises.writeFile(metadataPath, JSON.stringify(record, null, 2), { mode: 0o600, flag: 'wx' });
        const { audioFile, ...responseRecord } = record;
        return res.status(201).json({ recording: responseRecord });
      } catch (error) {
        if (audioPath) await fs.promises.rm(audioPath, { force: true }).catch(() => {});
        if (metadataPath) await fs.promises.rm(metadataPath, { force: true }).catch(() => {});
        console.error('AI recording processing failed:', error.message);
        return res.status(error.status || 502).json({ error: error.message || 'Не удалось обработать аудиозапись.' });
      }
    },
  );

  router.get('/recordings', async (_req, res) => {
    try {
      const names = await fs.promises.readdir(recordsDir).catch((error) => {
        if (error.code === 'ENOENT') return [];
        throw error;
      });
      const query = typeof _req.query.q === 'string'
        ? _req.query.q.trim().normalize('NFKC').toLocaleLowerCase('ru-RU').slice(0, 200)
        : '';
      const records = [];
      for (const name of names.filter((item) => item.endsWith('.json'))) {
        try {
          const record = JSON.parse(await fs.promises.readFile(path.join(recordsDir, name), 'utf8'));
          const searchable = [
            record.fileName,
            record.summary?.title,
            record.summary?.summary,
            record.transcript,
          ].filter(Boolean).join('\n').normalize('NFKC').toLocaleLowerCase('ru-RU');
          if (query && !searchable.includes(query)) continue;
          records.push({
            id: record.id,
            fileName: record.fileName,
            createdAt: record.createdAt,
            fileSize: record.fileSize,
            summary: record.summary,
            summaryWarning: record.summaryWarning,
            transcriptPreview: record.transcript.slice(0, 220),
          });
        } catch {
          // Ignore corrupt metadata files without exposing filesystem details.
        }
      }
      records.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
      return res.json({ recordings: records });
    } catch (error) {
      console.error('AI recording list failed:', error.message);
      return res.status(500).json({ error: 'Не удалось загрузить библиотеку AI-записей.' });
    }
  });

  router.get('/recordings/:id', async (req, res) => {
    try {
      const record = await readRecord(req.params.id);
      if (!record) return res.status(404).json({ error: 'Запись не найдена.' });
      const { audioFile, ...responseRecord } = record;
      return res.json({ recording: responseRecord });
    } catch (error) {
      console.error('AI recording read failed:', error.message);
      return res.status(500).json({ error: 'Не удалось открыть AI-запись.' });
    }
  });

  router.get('/recordings/:id/audio', async (req, res) => {
    try {
      const record = await readRecord(req.params.id);
      if (!record || !record.audioFile || path.basename(record.audioFile) !== record.audioFile) {
        return res.status(404).json({ error: 'Аудиофайл не найден.' });
      }
      const filePath = path.join(recordsDir, record.audioFile);
      await fs.promises.access(filePath, fs.constants.R_OK);
      res.setHeader('Content-Type', audioMimeType(record.fileName) || 'application/octet-stream');
      res.setHeader('Content-Disposition', 'attachment; filename="' + record.id + path.extname(record.fileName) + '"');
      return fs.createReadStream(filePath).pipe(res);
    } catch (error) {
      if (error.code === 'ENOENT') return res.status(404).json({ error: 'Аудиофайл не найден.' });
      console.error('AI audio download failed:', error.message);
      return res.status(500).json({ error: 'Не удалось скачать аудиофайл.' });
    }
  });

  router.delete('/recordings/:id', async (req, res) => {
    try {
      const record = await readRecord(req.params.id);
      if (!record) return res.status(404).json({ error: 'Запись не найдена.' });
      await fs.promises.rm(path.join(recordsDir, record.audioFile), { force: true });
      await fs.promises.rm(path.join(recordsDir, req.params.id + '.json'), { force: true });
      return res.sendStatus(204);
    } catch (error) {
      console.error('AI recording deletion failed:', error.message);
      return res.status(500).json({ error: 'Не удалось удалить AI-запись.' });
    }
  });

  return router;
}

module.exports = {
  MAX_AUDIO_BYTES,
  SUMMARY_SCHEMA,
  sanitizeFileName,
  audioMimeType,
  normalizeTranscription,
  extractOutputText,
  transcriptionRequestOptions,
  createAIRouter,
};
