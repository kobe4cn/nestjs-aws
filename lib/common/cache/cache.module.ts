import { Module } from '@nestjs/common';
import { CacheModule as CacheModuleBase } from '@nestjs/cache-manager';
import { Keyv } from 'keyv';
import { KeyvCacheableMemory } from 'cacheable';
import { createKeyv } from '@keyv/redis';
import { ConfigService } from '@nestjs/config';
import { ConfigEnum } from '../enum/config.enum';

function createRedisCache(
  redisType: string,
  redisNode: string,
  redisPass: string,
  redisUrl: string,
) {
  if (redisType === 'single') {
    const url = /^rediss?:\/\//.test(redisUrl)
      ? redisUrl
      : `redis://${redisUrl}`;
    return createKeyv({ url, password: redisPass });
  } else {
    // 过滤掉末尾可能存在的空字符串，避免无效节点导致连接异常
    const rootNodes = (redisNode || '')
      .split(',')
      .map((item) => item.trim())
      .filter(Boolean)
      .map((item: string) => {
        const node = item.split(':');
        return { url: `redis://${node[0]}:${node[1]}`, password: redisPass };
      });
    return createKeyv({ rootNodes });
  }
}

@Module({
  imports: [
    CacheModuleBase.registerAsync({
      isGlobal: true,
      inject: [ConfigService],
      useFactory: async (configService: ConfigService) => {
        const redisType = configService.get(ConfigEnum.REDIS_TYPE);
        const redisNode = configService.get(ConfigEnum.REDIS_NODE);
        const redisPass = configService.get(ConfigEnum.REDIS_PASS);
        const redisUrl = configService.get(ConfigEnum.REDIS_URL);
        // 配置中心读取到的环境变量转为数字毫秒数，若未配置则回退到 60 秒（60000 毫秒）
        const cacheTime =
          Number(configService.get(ConfigEnum.CACHE_TIME)) || 60000;

        return {
          ttl: cacheTime,
          stores: [
            // 一级内存缓存，TTL 需为毫秒
            new Keyv({
              store: new KeyvCacheableMemory({ ttl: cacheTime, lruSize: 5000 }),
            }),
            // 二级 Redis 缓存
            createRedisCache(redisType, redisNode, redisPass, redisUrl),
          ],
        };
      },
    }),
  ],
})
export class CacheModule {}
