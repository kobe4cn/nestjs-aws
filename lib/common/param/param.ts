import type { ExecutionContext } from '@nestjs/common';

/** Reads one route param for `@Can()`. */
export const param = (name: string) => (context: ExecutionContext) =>
  [context.switchToHttp().getRequest().params[name] as string] as const;
