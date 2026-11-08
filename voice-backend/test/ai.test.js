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
