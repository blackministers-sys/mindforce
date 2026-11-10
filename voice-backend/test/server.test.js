'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { app } = require('../src/server');

test('reports AI-only backend readiness without exposing secrets or requiring Twilio', async (t) => {
  const names = [
    'GOLOS_APP_API_TOKEN',
    'OPENAI_API_KEY',
    'TWILIO_ACCOUNT_SID',
    'TWILIO_AUTH_TOKEN',
    'TWILIO_API_KEY_SID',
    'TWILIO_API_SECRET',
    'TWILIO_APP_SID',
    'TWILIO_CALLER_ID',
    'ALLOWED_DIAL_PREFIXES',
  ];
  const previous = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  for (const name of names) delete process.env[name];
  process.env.GOLOS_APP_API_TOKEN = 'test-token-for-status-route';

  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    for (const name of names) {
      if (previous[name] === undefined) delete process.env[name];
      else process.env[name] = previous[name];
    }
  });

  const baseURL = 'http://127.0.0.1:' + server.address().port;
  const unauthorized = await fetch(baseURL + '/v1/status');
  assert.equal(unauthorized.status, 401);

  const headers = { Authorization: 'Bearer test-token-for-status-route' };
  let response = await fetch(baseURL + '/v1/status', { headers });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    aiAvailable: false,
    telephonyAvailable: false,
  });

  process.env.OPENAI_API_KEY = 'openai-secret-must-not-be-returned';
  response = await fetch(baseURL + '/v1/status', { headers });
  assert.deepEqual(await response.json(), {
    ok: true,
    aiAvailable: true,
    telephonyAvailable: false,
  });

  process.env.TWILIO_ACCOUNT_SID = 'AC-test';
  process.env.TWILIO_AUTH_TOKEN = 'twilio-auth-secret';
  process.env.TWILIO_API_KEY_SID = 'SK-test';
  process.env.TWILIO_API_SECRET = 'twilio-api-secret';
  process.env.TWILIO_APP_SID = 'AP-test';
  process.env.TWILIO_CALLER_ID = '+31612345678';
  process.env.ALLOWED_DIAL_PREFIXES = '+31';
  response = await fetch(baseURL + '/v1/status', { headers });
  assert.deepEqual(await response.json(), {
    ok: true,
    aiAvailable: true,
    telephonyAvailable: true,
  });
});
