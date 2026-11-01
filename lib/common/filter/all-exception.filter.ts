import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { HttpAdapterHost } from '@nestjs/core';
import { Logger } from 'nestjs-pino';
import requestIp from 'request-ip';

@Catch()
export class AllExceptionFilter<T> implements ExceptionFilter {
  constructor(
    private readonly logger: Logger,
    private readonly httpAdapterHost: HttpAdapterHost,
  ) {}

  catch(exception: T, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse();
    const request = ctx.getRequest();
    const { httpAdapter } = this.httpAdapterHost;
    const errObj = (exception ?? {}) as Record<string, any>;
    const httpStatus =
      exception instanceof HttpException
        ? exception.getStatus()
        : (errObj.statusCode ?? HttpStatus.INTERNAL_SERVER_ERROR);

    // 提取详细错误信息：兼容 HttpException.getResponse()、TypeORM QueryFailedError (detail/code/constraint) 与普通 Error.message
    const errorDetail =
      exception instanceof HttpException
        ? exception.getResponse()
        : errObj.response || {
            message: errObj.message || 'Internal Server Error',
            ...(errObj.detail ? { detail: errObj.detail } : {}),
            ...(errObj.code ? { code: errObj.code } : {}),
            ...(errObj.table ? { table: errObj.table } : {}),
            ...(errObj.constraint ? { constraint: errObj.constraint } : {}),
            ...(errObj.issues ? { issues: errObj.issues } : {}),
          };

    const responseBody = {
      statusCode: httpStatus,
      header: request.header,
      query: request.query,
      body: request.body,
      params: request.params,
      timestamp: new Date().toISOString(),
      ip: requestIp.getClientIp(request),
      exception: errObj.name ?? 'Internal Server Error',
      message: errObj.message ?? 'Internal Server Error',
      error: errorDetail,
    };
    console.error('=== CAUGHT EXCEPTION ===\n', exception);
    this.logger.error(
      {
        ...responseBody,
        message: (exception as any)?.message,
        stack: (exception as any)?.stack,
      },
      '[nestjs]',
    );
    httpAdapter.reply(response, responseBody, httpStatus);
  }
}
