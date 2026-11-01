import { HttpAdapterHost, NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { Logger } from 'nestjs-pino';
import { ConfigService } from '@nestjs/config';
import { VersioningType } from '@nestjs/common';
import { ConfigEnum } from '@app/common/enum/config.enum';
import { AllExceptionFilter } from '@app/common/filter/all-exception.filter';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  const configService = app.get(ConfigService);
  const port = configService.get<number>(ConfigEnum.APP_PORT, 3000);
  const prefix = configService.get<string>(ConfigEnum.PREFIX, 'api');
  const version = configService
    .get<string>(ConfigEnum.VERSION, '1')
    .split(',')
    .map((item) => item.trim());
  console.log(version);
  const cors = configService.get<boolean>(ConfigEnum.CORS, false);
  app.enableCors(cors);
  app.setGlobalPrefix(prefix);
  app.enableVersioning({
    type: VersioningType.URI,
    prefix: 'v',
    defaultVersion: [...version],
  });
  app.useLogger(app.get(Logger));
  app.flushLogs();
  app.enableShutdownHooks();
  app.useGlobalFilters(
    new AllExceptionFilter(app.get(Logger), app.get(HttpAdapterHost)),
  );
  const logger = app.get(Logger);

  await app.listen(port);
  logger.log(`Application is running on: ${await app.getUrl()}`);
}
void bootstrap();
