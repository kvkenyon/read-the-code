export class AppError extends Error {
  constructor(
    message: string,
    public readonly code: string,
    public readonly exitCode = 1,
    public readonly statusCode = 400,
  ) {
    super(message);
    this.name = 'AppError';
  }
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
