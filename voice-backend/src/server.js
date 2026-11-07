'use strict';

require('dotenv').config();

const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const twilio = require('twilio');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Readable } = require('node:stream');
const { isE164, isAllowedDestination } = require('./phone');

const app = express();
const PORT = Number(process.env.PORT || 3000);
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || '').replace(/\/$/, '');
const DATA_DIR = process.env.DATA_DIR || path.join(process.cwd(), 'data');
const RECORDING_EVENTS_FILE = path.join(DATA_DIR, 'recording-events.jsonl');

app.disable('x-powered-by');
app.set('trust proxy', process.env.TRUST_PROXY_HOPS ? Number(process.env.TRUST_PROXY_HOPS) : 1);
app.use(helmet({ contentSecurityPolicy: false }));
app.use(express.json({ limit: '100kb' }));
app.use(express.urlencoded({ extended: false, limit: '100kb' }));

const tokenLimiter = rateLimit({
  windowMs: 60 * 1000,
  limit: 10,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: 'Слишком много запросов токена. Попробуйте позже.' },
});

function requireEnv(names) {
  const missing = names.filter((name) => !process.env[name]);
  if (missing.length) {
    const error = new Error('Не заданы переменные окружения: ' + missing.join(', '));
    error.status = 503;
    throw error;
  }
}

function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function requireAppToken(req, res, next) {
  const expected = process.env.GOLOS_APP_API_TOKEN;
  const supplied = (req.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!expected || !safeEqual(supplied, expected)) {
    return res.status(401).json({ error: 'Требуется действительный токен приложения.' });
  }
  return next();
}

function requireTwilioSignature(req, res, next) {
  try {
    requireEnv(['TWILIO_AUTH_TOKEN', 'PUBLIC_BASE_URL']);
    const signature = req.get('x-twilio-signature') || '';
    const requestUrl = PUBLIC_BASE_URL + req.originalUrl;
    if (!twilio.validateRequest(process.env.TWILIO_AUTH_TOKEN, signature, requestUrl, req.body || {})) {
      return res.status(403).send('Invalid Twilio signature');
    }
    return next();
  } catch (error) {
    return res.status(error.status || 503).send(error.message);
  }
}

function publicUrl(route) {
  return PUBLIC_BASE_URL + route;
}

function allowedPrefixes() {
  return (process.env.ALLOWED_DIAL_PREFIXES || '').split(',').map((item) => item.trim()).filter(Boolean);
}

function sendTwiML(res, voiceResponse) {
  res.type('text/xml').send(voiceResponse.toString());
}

function addRecordingDial(response, destination, destinationType, requireDestinationConsent = true) {
  const callerId = process.env.TWILIO_CALLER_ID;
  if (!isE164(callerId)) {
    throw new Error('TWILIO_CALLER_ID должен быть номером E.164, принадлежащим вашему аккаунту Twilio.');
  }

  const dial = response.dial({
    callerId,
    answerOnBridge: true,
    record: 'record-from-answer-dual',
    recordingStatusCallback: publicUrl('/v1/voice/recording-events'),
    recordingStatusCallbackMethod: 'POST',
    recordingStatusCallbackEvent: 'completed',
  });

  if (destinationType === 'client') {
    if (requireDestinationConsent) {
      dial.client({ url: publicUrl('/v1/voice/whisper'), method: 'POST' }, destination);
    } else {
      dial.client(destination);
    }
  } else {
    dial.number({ url: publicUrl('/v1/voice/whisper'), method: 'POST' }, destination);
  }
}

app.get('/health', (_req, res) => res.json({ ok: true, service: 'golos-voice-backend' }));

app.post('/v1/voice/token', tokenLimiter, requireAppToken, (req, res) => {
  try {
    requireEnv(['TWILIO_ACCOUNT_SID', 'TWILIO_API_KEY_SID', 'TWILIO_API_SECRET', 'TWILIO_APP_SID']);
    const identityInput = typeof req.body.identity === 'string' ? req.body.identity : 'golos-user';
    const identity = identityInput.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64) || 'golos-user';
    const grantOptions = { outgoingApplicationSid: process.env.TWILIO_APP_SID, incomingAllow: true };
    if (process.env.TWILIO_PUSH_CREDENTIAL_SID) {
      grantOptions.pushCredentialSid = process.env.TWILIO_PUSH_CREDENTIAL_SID;
    }
    const grant = new twilio.jwt.AccessToken.VoiceGrant(grantOptions);
    const token = new twilio.jwt.AccessToken(
      process.env.TWILIO_ACCOUNT_SID,
      process.env.TWILIO_API_KEY_SID,
      process.env.TWILIO_API_SECRET,
      { identity, ttl: 3600 },
    );
    token.addGrant(grant);
    return res.json({ accessToken: token.toJwt(), identity, expiresIn: 3600 });
  } catch (error) {
    return res.status(error.status || 500).json({ error: error.message || 'Не удалось создать голосовой токен.' });
  }
});

app.post('/v1/voice/twiml', requireTwilioSignature, (req, res) => {
  const destination = String(req.body.to || req.body.To || '').trim();
  const response = new twilio.twiml.VoiceResponse();

  if (!isAllowedDestination(destination, allowedPrefixes())) {
    response.say({ language: 'ru-RU' }, 'Этот номер не разрешён настройками приложения.');
    response.hangup();
    return sendTwiML(res, response);
  }

  response.say(
    { language: 'ru-RU' },
    'Внимание. Этот разговор записывается приложением Голос. Продолжая разговор, вы подтверждаете, что участники уведомлены о записи.',
  );
  try {
    addRecordingDial(response, destination, 'pstn');
    return sendTwiML(res, response);
  } catch (error) {
    const failure = new twilio.twiml.VoiceResponse();
    failure.say({ language: 'ru-RU' }, 'Не удалось настроить звонок. Проверьте конфигурацию сервера.');
    failure.hangup();
    console.error('TwiML configuration error:', error.message);
    return sendTwiML(res, failure);
  }
});

app.post('/v1/voice/incoming', requireTwilioSignature, (_req, res) => {
  const response = new twilio.twiml.VoiceResponse();
  const gather = response.gather({
    numDigits: 1,
    timeout: 15,
    action: publicUrl('/v1/voice/incoming-consent'),
    method: 'POST',
  });
  gather.say(
    { language: 'ru-RU' },
    'Этот звонок будет записываться. Чтобы согласиться на запись и продолжить, нажмите 1. Если вы не согласны, не нажимайте кнопку.',
  );
  response.say({ language: 'ru-RU' }, 'Согласие на запись не получено. Вызов завершается.');
  response.hangup();
  return sendTwiML(res, response);
});

app.post('/v1/voice/incoming-consent', requireTwilioSignature, async (req, res) => {
  const accepted = String(req.body.Digits || '') === '1';
  const event = {
    callSid: String(req.body.CallSid || ''),
    party: 'incoming-caller',
    accepted,
    createdAt: new Date().toISOString(),
  };
  try {
    await fs.promises.mkdir(DATA_DIR, { recursive: true });
    await fs.promises.appendFile(
      path.join(DATA_DIR, 'recording-consents.jsonl'),
      JSON.stringify(event) + '\n',
      { mode: 0o600 },
    );
  } catch (error) {
    console.error('Could not store incoming recording consent:', error);
    return res.status(500).send('Could not store consent');
  }

  const response = new twilio.twiml.VoiceResponse();
  if (!accepted) {
    response.say({ language: 'ru-RU' }, 'Согласие на запись не получено. Вызов завершается.');
    response.hangup();
    return sendTwiML(res, response);
  }

  response.say({ language: 'ru-RU' }, 'Спасибо. Соединяем вас с пользователем приложения Голос.');
  try {
    addRecordingDial(response, 'golos-user', 'client', false);
    return sendTwiML(res, response);
  } catch (error) {
    const failure = new twilio.twiml.VoiceResponse();
    failure.say({ language: 'ru-RU' }, 'Сервис временно недоступен.');
    failure.hangup();
    console.error('Incoming call configuration error:', error.message);
    return sendTwiML(res, failure);
  }
});

app.post('/v1/voice/whisper', requireTwilioSignature, (_req, res) => {
  const response = new twilio.twiml.VoiceResponse();
  const gather = response.gather({
    numDigits: 1,
    timeout: 15,
    action: publicUrl('/v1/voice/recording-consent'),
    method: 'POST',
  });
  gather.say(
    { language: 'ru-RU' },
    'Разговор будет записываться. Чтобы согласиться на запись и продолжить разговор, нажмите 1. Если вы не согласны, просто не нажимайте кнопку.',
  );
  response.say({ language: 'ru-RU' }, 'Согласие на запись не получено. Вызов завершается.');
  response.hangup();
  return sendTwiML(res, response);
});

app.post('/v1/voice/recording-consent', requireTwilioSignature, async (req, res) => {
  const accepted = String(req.body.Digits || '') === '1';
  const event = {
    callSid: String(req.body.CallSid || ''),
    accepted,
    createdAt: new Date().toISOString(),
  };
  try {
    await fs.promises.mkdir(DATA_DIR, { recursive: true });
    await fs.promises.appendFile(
      path.join(DATA_DIR, 'recording-consents.jsonl'),
      JSON.stringify(event) + '\n',
      { mode: 0o600 },
    );
  } catch (error) {
    console.error('Could not store recording consent:', error);
    return res.status(500).send('Could not store consent');
  }

  const response = new twilio.twiml.VoiceResponse();
  if (accepted) {
    response.say({ language: 'ru-RU' }, 'Спасибо. Соединяем вас.');
  } else {
    response.say({ language: 'ru-RU' }, 'Согласие на запись не получено. Вызов завершается.');
    response.hangup();
  }
  return sendTwiML(res, response);
});

app.post('/v1/voice/recording-events', requireTwilioSignature, async (req, res) => {
  try {
    const event = {
      recordingSid: String(req.body.RecordingSid || ''),
      callSid: String(req.body.CallSid || ''),
      status: String(req.body.RecordingStatus || ''),
      duration: Number(req.body.RecordingDuration || 0),
      channels: Number(req.body.RecordingChannels || 0),
      mediaUrl: String(req.body.RecordingUrl || ''),
      createdAt: new Date().toISOString(),
    };
    if (!event.recordingSid || event.status !== 'completed') return res.sendStatus(204);
    await fs.promises.mkdir(DATA_DIR, { recursive: true });
    await fs.promises.appendFile(RECORDING_EVENTS_FILE, JSON.stringify(event) + '\n', { mode: 0o600 });
    console.info('Completed call recording saved:', event.recordingSid);
    return res.sendStatus(204);
  } catch (error) {
    console.error('Could not save recording event:', error);
    return res.sendStatus(500);
  }
});

app.get('/v1/voice/recordings', requireAppToken, async (_req, res) => {
  try {
    const raw = await fs.promises.readFile(RECORDING_EVENTS_FILE, 'utf8').catch((error) => {
      if (error.code === 'ENOENT') return '';
      throw error;
    });
    const latestBySid = new Map();
    for (const line of raw.split('\n').filter(Boolean)) {
      try {
        const event = JSON.parse(line);
        latestBySid.set(event.recordingSid, event);
      } catch {
        // Ignore an incomplete final line after an interrupted write.
      }
    }
    const recordings = [...latestBySid.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
    return res.json({
      recordings: recordings.map(({ mediaUrl, ...item }) => ({
        ...item,
        audioPath: '/v1/voice/recordings/' + encodeURIComponent(item.recordingSid) + '/audio',
      })),
    });
  } catch (error) {
    return res.status(500).json({ error: 'Не удалось прочитать список записей.' });
  }
});

app.get('/v1/voice/recordings/:recordingSid/audio', requireAppToken, async (req, res) => {
  try {
    requireEnv(['TWILIO_ACCOUNT_SID', 'TWILIO_AUTH_TOKEN']);
    if (!/^RE[0-9a-fA-F]{32}$/.test(req.params.recordingSid)) {
      return res.status(400).json({ error: 'Некорректный идентификатор записи.' });
    }
    const raw = await fs.promises.readFile(RECORDING_EVENTS_FILE, 'utf8').catch((error) => {
      if (error.code === 'ENOENT') return '';
      throw error;
    });
    const found = raw.split('\n').filter(Boolean).map((line) => {
      try { return JSON.parse(line); } catch { return null; }
    }).find((item) => item && item.recordingSid === req.params.recordingSid && item.status === 'completed');
    if (!found || !found.mediaUrl) return res.status(404).json({ error: 'Запись не найдена.' });

    const mediaUrl = found.mediaUrl.endsWith('.mp3') ? found.mediaUrl : found.mediaUrl + '.mp3';
    const authorization = Buffer.from(process.env.TWILIO_ACCOUNT_SID + ':' + process.env.TWILIO_AUTH_TOKEN).toString('base64');
    const upstream = await fetch(mediaUrl, { headers: { Authorization: 'Basic ' + authorization } });
    if (!upstream.ok || !upstream.body) {
      console.error('Twilio media download failed:', upstream.status);
      return res.status(502).json({ error: 'Не удалось получить аудиофайл у телефонного провайдера.' });
    }
    res.setHeader('Content-Type', 'audio/mpeg');
    res.setHeader('Content-Disposition', 'attachment; filename="' + req.params.recordingSid + '.mp3"');
    return Readable.fromWeb(upstream.body).pipe(res);
  } catch (error) {
    console.error('Recording download failed:', error);
    return res.status(error.status || 500).json({ error: 'Ошибка загрузки аудиозаписи.' });
  }
});

app.use((error, _req, res, _next) => {
  console.error('Unhandled request error:', error);
  res.status(500).json({ error: 'Внутренняя ошибка сервера.' });
});

if (require.main === module) {
  fs.promises.mkdir(DATA_DIR, { recursive: true }).then(() => {
    app.listen(PORT, '0.0.0.0', () => console.info('Golos Voice backend listening on ' + PORT));
  }).catch((error) => {
    console.error('Could not create DATA_DIR:', error);
    process.exit(1);
  });
}

module.exports = { app, safeEqual, allowedPrefixes };
