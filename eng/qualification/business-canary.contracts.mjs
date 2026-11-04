// Failure evidence must never serialize HTTP bodies, assertion values or identifiers.
const reviewedProblemCodes = new Set([
  ...['MissingBinding', 'InvalidRequest', 'UnknownPolicy', 'CountryMismatch', 'CountryDisabled',
    'CountryNotApproved', 'PolicyNotApproved', 'ContentDigestMismatch', 'PolicyNotEffective', 'PolicyExpired',
    'AccommodationTypeUnsupported', 'DataRegionNotPermitted', 'TransferProfileNotPermitted',
    'RetentionPolicyNotPermitted', 'RequiredAcknowledgementMissing', 'PurposeUnsupported', 'SurfaceUnsupported',
    'SourceProvenanceUnsupported', 'RightsResponsePolicyNotPermitted', 'TimeZoneNotPermitted',
    'DeadlineCalculationFailed'].map(reason => 'Reservations.CountryPolicyDenied.' + reason),
  ...['WorkspaceProcessingRestricted', 'WorkspaceProcessingAdmissionUnavailable', 'PropertyNotFound',
    'PropertyInactive', 'PropertyTimeZoneUnavailable', 'CreationOperationConflict', 'InventoryUnitNotFound',
    'InventoryUnitPropertyMismatch', 'TenantRequired'].map(code => 'Reservations.' + code)
]);

class UnexpectedUiResponseError extends Error {
  constructor(status, problem) {
    super('Real UI mutation returned an unexpected status.');
    this.name = 'UnexpectedUiResponseError';
    this.status = status;
    if (reviewedProblemCodes.has(problem?.title)) this.problemCode = problem.title;
  }
}

export function assertExpectedUiStatus(status, expected, problem) {
  if (!expected.includes(status)) throw new UnexpectedUiResponseError(status, problem);
}

export function bookingReceiptObservation(request, receipt) {
  const requestHasOperationId = typeof request?.operationId === 'string' && request.operationId.length > 0;
  const receiptHasReservationId = typeof receipt?.reservationId === 'string' && receipt.reservationId.length > 0;
  return { requestHasOperationId, receiptHasReservationId,
    reservationIdMatchesOperationId: requestHasOperationId && receiptHasReservationId
      && receipt.reservationId === request.operationId };
}

export function safeBusinessFailure(stage, error) {
  const known = new Set(['AssertionError', 'TimeoutError', 'Error']);
  const type = error instanceof UnexpectedUiResponseError ? error.name
    : known.has(error?.name) ? error.name : 'Error';
  const evidence = { stage, type };
  if (error instanceof UnexpectedUiResponseError && Number.isInteger(error.status)
      && error.status >= 100 && error.status <= 599) evidence.httpStatus = error.status;
  if (error instanceof UnexpectedUiResponseError && reviewedProblemCodes.has(error.problemCode)) {
    evidence.problemCode = error.problemCode;
  }
  return evidence;
}
