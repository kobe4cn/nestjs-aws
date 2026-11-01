import { NestFactory } from '@nestjs/core';
import { OrderModule } from './order.module';
import { AsyncMicroserviceOptions, Transport } from '@nestjs/microservices';
import { ConfigService } from '@nestjs/config';
import { ConfigEnum } from '@app/common/enum/config.enum';
async function bootstrap() {
  const app = await NestFactory.createMicroservice<AsyncMicroserviceOptions>(
    OrderModule,
    {
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        transport: Transport.TCP,
        options: {
          // 容器环境下必须绑定 0.0.0.0，否则默认仅监听 127.0.0.1 导致跨容器无法通信
          host: configService.get<string>(ConfigEnum.ORDER_BIND_HOST, '0.0.0.0'),
          port: Number(configService.getOrThrow(ConfigEnum.APP_PORT)),
        },
      }),
    },
  );
  app.enableShutdownHooks();
  const config = app.get(ConfigService);
  await app.listen();
  console.log(
    `Order microservice is listening on port ${config.getOrThrow(ConfigEnum.APP_PORT)},NODE_ENV is ${config.getOrThrow(ConfigEnum.NODE_ENV)}`,
  );
}
void bootstrap();
