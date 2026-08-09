export const LIMITS = {
  maxPatchBytesPerFile: 1_000_000,
  maxPatchBytesTotal: 8_000_000,
  maxFiles: 2_000,
  maxCommentBytes: 20_000,
  maxSubmissionBytes: 100_000,
  maxCommentsPerSubmission: 100,
  maxRequestBytes: 128_000,
  maxRefBytes: 512,
  maxPathBytes: 4_096,
} as const;
