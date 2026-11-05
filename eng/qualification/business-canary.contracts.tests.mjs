import assert from 'node:assert/strict';
import test from 'node:test';
import { assertExpectedUiStatus, bookingReceiptObservation, recoverInventoryProjectionCreate, safeBusinessFailure } from './business-canary.contracts.mjs';

test('UI response acceptance preserves exactly the caller status set', () => {
  for (const status of [200, 201, 202]) assert.doesNotThrow(() => assertExpectedUiStatus(status, [200, 201, 202]));
  for (const status of [204, 400, 401, 403, 409, 429, 500]) {
    assert.throws(() => assertExpectedUiStatus(status, [200, 201, 202]), error => {
      assert.deepEqual(safeBusinessFailure('actual-booking-create-http-response', error), {
        stage: 'actual-booking-create-http-response', type: 'UnexpectedUiResponseError', httpStatus: status
      });
      return true;
    });
  }
  assert.throws(() => assertExpectedUiStatus(202, [200]));
});

test('receipt evidence contains only booleans for matched, missing and different identities', () => {
  const secret = 'synthetic-private-identifier';
  for (const [request, receipt, expected] of [
    [{ operationId: secret }, { reservationId: secret }, [true, true, true]],
    [{ operationId: secret }, { reservationId: 'different-private-identifier' }, [true, true, false]],
    [{}, {}, [false, false, false]],
    [undefined, null, [false, false, false]],
    [{ operationId: '' }, { reservationId: 123 }, [false, false, false]]
  ]) {
    const evidence = bookingReceiptObservation(request, receipt);
    assert.deepEqual(Object.values(evidence), expected);
    assert(Object.values(evidence).every(value => typeof value === 'boolean'));
    assert(!JSON.stringify(evidence).includes(secret));
  }
});

test('assertion payloads and arbitrary error properties are excluded from reports', () => {
  const secret = 'synthetic-password-token-response-body';
  const error = new assert.AssertionError({ actual: secret, expected: secret + '-other', message: secret });
  error.body = secret; error.status = 403; error.accessToken = secret;
  const evidence = safeBusinessFailure('actual-booking-receipt-operation-identity', error);
  assert.deepEqual(evidence, { stage: 'actual-booking-receipt-operation-identity', type: 'AssertionError' });
  assert(!JSON.stringify(evidence).includes(secret));
  assert.deepEqual(safeBusinessFailure('bounded-stage', { name: secret, status: 403, message: secret }),
    { stage: 'bounded-stage', type: 'Error' });
});

test('invalid HTTP status values cannot enter evidence', () => {
  for (const status of ['synthetic-private-string', NaN, 0, 600, 403.5]) {
    assert.throws(() => assertExpectedUiStatus(status, [200]), error => {
      assert.deepEqual(safeBusinessFailure('bounded-stage', error),
        { stage: 'bounded-stage', type: 'UnexpectedUiResponseError' });
      return true;
    });
  }
});

test('only exact reviewed problem codes survive; response detail and arbitrary titles never do', () => {
  const secret = 'synthetic-private-response-detail';
  for (const title of ['Reservations.CountryPolicyDenied.MissingBinding', 'Reservations.InventoryUnitNotFound',
    secret, 'Reservations.CountryPolicyDenied.' + secret]) {
    assert.throws(() => assertExpectedUiStatus(409, [200], { title, detail: secret, token: secret }), error => {
      const evidence = safeBusinessFailure('actual-booking-create-http-response', error);
      assert(!JSON.stringify(evidence).includes(secret));
      assert.equal(evidence.problemCode, title.includes(secret) ? undefined : title);
      return true;
    });
  }
});

function refusal(status = 409, title = 'Reservations.InventoryUnitNotFound') {
  try { assertExpectedUiStatus(status, [200, 201, 202], { title }); }
  catch (error) { return error; }
  throw new Error('Expected a refusal fixture.');
}

test('fresh projection lag uses the existing retry control within one shared response budget', async () => {
  let time = 0;
  const observations = [];
  const result = await recoverInventoryProjectionCreate(async observation => {
    observations.push(observation);
    if (observations.length < 3) throw refusal();
    return 'accepted-private-result';
  }, { now: () => time, pause: async ms => { time += ms; } });
  assert.deepEqual(result, { result: 'accepted-private-result', attempts: 3, retries: 2 });
  assert.deepEqual(observations.map(x => x.retry), [false, true, true]);
  assert.deepEqual(observations.map(x => x.remainingMs), [90000, 89000, 88000]);
});

test('permission, different conflicts, throttling, server and transport failures never replay', async () => {
  for (const error of [refusal(403), refusal(409, 'Reservations.CreationOperationConflict'),
    refusal(400, 'Reservations.InventoryUnitPropertyMismatch'), refusal(429), refusal(500),
    new Error('synthetic-private-transport-message'),
    Object.assign(new Error('synthetic-private-spoof'), { name: 'UnexpectedUiResponseError',
      status: 409, problemCode: 'Reservations.InventoryUnitNotFound' })]) {
    let calls = 0;
    await assert.rejects(recoverInventoryProjectionCreate(async () => { calls += 1; throw error; }), value => value === error);
    assert.equal(calls, 1);
  }
});

test('permanent missing projection fails at the original deadline without a further write', async () => {
  let time = 0, calls = 0;
  await assert.rejects(recoverInventoryProjectionCreate(async ({ remainingMs }) => {
    assert(remainingMs > 0 && remainingMs <= 90000);
    calls += 1;
    throw refusal();
  }, { now: () => time, pause: async ms => { time += ms; } }), error => {
    assert.deepEqual(safeBusinessFailure('bounded-stage', error),
      { stage: 'bounded-stage', type: 'ProjectionConvergenceTimeout' });
    return true;
  });
  assert.equal(time, 90000);
  assert.equal(calls, 90);
});

test('an exhausted response consumes the budget without another UI attempt', async () => {
  let time = 0, calls = 0;
  await assert.rejects(recoverInventoryProjectionCreate(async () => {
    calls += 1; time = 90000; throw refusal();
  }, { now: () => time, pause: async () => assert.fail('No delay or new attempt after deadline.') }));
  assert.equal(calls, 1);
});

test('request identity or payload mismatch remains a terminal assertion with private values excluded', async () => {
  const secret = 'synthetic-private-payload';
  let time = 0, calls = 0;
  await assert.rejects(recoverInventoryProjectionCreate(async () => {
    calls += 1;
    if (calls === 1) throw refusal();
    assert.deepEqual({ operationId: secret }, { operationId: secret + '-changed' });
  }, { now: () => time, pause: async ms => { time += ms; } }), error => {
    const evidence = safeBusinessFailure('bounded-stage', error);
    assert.deepEqual(evidence, { stage: 'bounded-stage', type: 'AssertionError' });
    assert(!JSON.stringify(evidence).includes(secret));
    return true;
  });
  assert.equal(calls, 2);
});

test('the original create budget cannot be increased by the harness caller', async () => {
  for (const budgetMs of [0, -1, 90001, Infinity, NaN]) {
    await assert.rejects(recoverInventoryProjectionCreate(async () => assert.fail('Invalid budget must not dispatch.'), { budgetMs }), RangeError);
  }
});
