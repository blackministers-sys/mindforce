'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  MAX_AUDIO_BYTES,
  sanitizeFileName,
  audioMimeType,
  normalizeTranscription,
  extractOutputText,
  transcriptionRequestOptions,
  transcribeAudio,
  summarizeTranscript,
} = require('../src/ai');

test('sanitizes incoming audio file names and blocks path traversal', () => {
  assert.equal(sanitizeFileName('../../voice note.m4a'), 'voice-note.m4a');
  assert.equal(sanitizeFileName('C:\\temp\\meeting.wav'), 'meeting.wav');
  assert.equal(sanitizeFileName(''), 'recording');
});

test('accepts only documented audio container extensions', () => {
  assert.equal(audioMimeType('meeting.m4a'), 'audio/mp4');
  assert.equal(audioMimeType('speech.mp3'), 'audio/mpeg');
  assert.equal(audioMimeType('session.webm'), 'audio/webm');
  assert.equal(audioMimeType('voice.aac'), null);
});

test('normalizes diarized transcription segments and preserves speaker/time labels', () => {
  const result = normalizeTranscription({
    segments: [
      { start: 0.2, end: 1.7, speaker: 'speaker_0', text: 'Здравствуйте.' },
      { start: 1.8, end: 2.9, speaker: 'speaker_1', text: 'Добрый день.' },
    ],
  });
  assert.equal(result.segments.length, 2);
  assert.equal(result.segments[0].speaker, 'speaker_0');
  assert.equal(result.segments[0].start, 0.2);
  assert.equal(result.text, 'speaker_0: Здравствуйте.\nspeaker_1: Добрый день.');
});

test('uses the supplied transcript text when available', () => {
  const result = normalizeTranscription({
    text: 'Полная расшифровка.',
    segments: [{ start: 0, end: 1, text: 'Фрагмент.' }],
  });
  assert.equal(result.text, 'Полная расшифровка.');
});

test('rejects empty transcription results and extracts Responses API text', () => {
  assert.throws(() => normalizeTranscription({ segments: [] }), /пустую расшифровку/);
  assert.equal(extractOutputText({ output: [{ type: 'message', content: [{ type: 'output_text', text: 'Конспект' }] }] }), 'Конспект');
  assert.equal(MAX_AUDIO_BYTES, 23 * 1024 * 1024);
});

test('uses diarized JSON and automatic chunking for long multi-speaker recordings', () => {
  assert.deepEqual(transcriptionRequestOptions('gpt-4o-transcribe-diarize'), {
    responseFormat: 'diarized_json',
    chunkingStrategy: 'auto',
  });
});

test('supports the current transcription model without diarization metadata', () => {
  assert.deepEqual(transcriptionRequestOptions('gpt-transcribe'), {
    responseFormat: 'json',
    chunkingStrategy: null,
  });
});

test('sends diarized transcription to the OpenAI Audio API with VAD chunking', async () => {
  const originalFetch = global.fetch;
  const originalKey = process.env.OPENAI_API_KEY;
  let captured;
  process.env.OPENAI_API_KEY = 'test-api-key';
  global.fetch = async (url, options) => {
    captured = { url, options };
    return new Response(JSON.stringify({
      text: 'Привет.',
      segments: [{ start: 0, end: 1, speaker: 'speaker_0', text: 'Привет.' }],
    }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    const result = await transcribeAudio(Buffer.from('fake-audio'), 'meeting.m4a', 'audio/mp4');
    assert.equal(captured.url, 'https://api.openai.com/v1/audio/transcriptions');
    assert.equal(captured.options.headers.Authorization, 'Bearer test-api-key');
    assert.equal(captured.options.body.get('model'), 'gpt-4o-transcribe-diarize');
    assert.equal(captured.options.body.get('response_format'), 'diarized_json');
    assert.equal(captured.options.body.get('chunking_strategy'), 'auto');
    assert.equal(result.segments[0].speaker, 'speaker_0');
  } finally {
    global.fetch = originalFetch;
    if (originalKey === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = originalKey;
  }
});

test('requests a structured Russian summary from GPT-6 Luna with reasoning disabled', async () => {
  const originalFetch = global.fetch;
  const originalKey = process.env.OPENAI_API_KEY;
  const expected = {
    title: 'План встречи',
    summary: 'Обсудили задачи.',
    key_points: ['Сроки'],
    decisions: ['Согласовали план'],
    tasks: [{ task: 'Подготовить документ', owner: null, due_date: null }],
    open_questions: [],
  };
  let requestBody;
  process.env.OPENAI_API_KEY = 'test-api-key';
  global.fetch = async (url, options) => {
    requestBody = JSON.parse(options.body);
    return new Response(JSON.stringify({ output_text: JSON.stringify(expected) }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  };
  try {
    const result = await summarizeTranscript({ text: 'Участники обсудили план.' });
    assert.equal(result.title, expected.title);
    assert.equal(requestBody.model, 'gpt-6-luna');
    assert.equal(requestBody.reasoning.effort, 'none');
    assert.equal(requestBody.store, false);
    assert.equal(requestBody.text.format.type, 'json_schema');
    assert.equal(requestBody.text.format.strict, true);
    assert.ok(requestBody.instructions.includes('Не выдумывай'));
  } finally {
    global.fetch = originalFetch;
    if (originalKey === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = originalKey;
  }
});
