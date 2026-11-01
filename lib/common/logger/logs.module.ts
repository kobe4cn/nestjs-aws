import { Global, Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { LoggerModule } from 'nestjs-pino';
import { consoleTransport } from './createLogTransport';
import { ConfigEnum } from '../enum/config.enum';

@Module({
  imports: [
    LoggerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: async (config: ConfigService) => {
        // const log_on = config.get(ConfigEnum.LOG_ON);
        // const logs_type = config.get(ConfigEnum.LOG_TYPE).split('|');
        // const targets: any[] = [];
        // if (log_on) {
        //   logs_type.forEach((t: string) => {
        //     const level = t.toLowerCase();
        //     const filepath = `${config.get(ConfigEnum.LOG_PATH)}/${level.toUpperCase()}.log`;

        //     console.log(`level: ${level}, filepath: ${filepath}`);
        //     targets.push(createLogTransport(level, filepath));
        //   });
        // }
        const isProd = config.getOrThrow(ConfigEnum.NODE_ENV) === 'production';
        return {
          // 生产环境直接向 stdout 输出标准 JSON 结构日志供 AWS CloudWatch 采集，避免空 targets 导致日志丢失
          pinoHttp: isProd
            ? { level: 'info' }
            : {
                transport: {
                  // targets: [consoleTransport, ...(log_on ? targets : [])],
                  targets: [consoleTransport],
                },
              },
        };
      },
    }),
  ],
})
export class LogsModule {}
