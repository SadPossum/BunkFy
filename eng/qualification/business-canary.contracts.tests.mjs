import assert from 'node:assert/strict';
import test from 'node:test';
import { assertExpectedUiStatus, bookingReceiptObservation, safeBusinessFailure } from './business-canary.contracts.mjs';

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
