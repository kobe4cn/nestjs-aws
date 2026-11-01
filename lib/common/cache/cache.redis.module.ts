import { Module } from '@nestjs/common';
import { RedisModule } from '@nestjs-modules/ioredis';
import { ConfigService } from '@nestjs/config';
import { CacheModule } from './cache.module';
import { ConfigEnum } from '../enum/config.enum';
@Module({
  imports: [
    RedisModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => {
        const redistype = configService.get(ConfigEnum.REDIS_TYPE);
        if (redistype === 'single') {
          const rawUrl = configService.get<string>(
            ConfigEnum.REDIS_URL,
            'localhost:6379',
          );
          // 兼容无协议前缀的 host:port 格式以及 AWS ElastiCache TLS 的 rediss:// 协议
          const url = /^rediss?:\/\//.test(rawUrl)
            ? rawUrl
            : `redis://${rawUrl}`;
          return {
            type: 'single',
            url,
            options: {
              password: configService.get(ConfigEnum.REDIS_PASS),
            },
          };
        } else {
          const redisNode = configService
            .get(ConfigEnum.REDIS_NODE)
            .split(',')
            .map((item: string) => {
              const node = item.split(':');
              return {
                host: node[0],
                port: Number(node[1]),
              };
            });
          return {
            type: 'cluster',
            nodes: redisNode,
            options: {
              redisOptions: {
                password: configService.get(ConfigEnum.REDIS_PASS),
              },
            },
          };
        }
      },
    }),
    CacheModule,
  ],
})
export class CacheRedisModule {}
