import { Controller, Get, Inject, Version } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Logger } from 'nestjs-pino';
import { InjectRedis } from '@nestjs-modules/ioredis';
import Redis from 'ioredis';
import { CACHE_MANAGER, Cache } from '@nestjs/cache-manager';
import { MailerService } from '@nestjs-modules/mailer';
import { Public } from '@nestjs/authentication';
let a = 1;
@Public()
@Controller()
export class AppController {
  constructor(
    private readonly logger: Logger,
    private readonly configService: ConfigService,
    @InjectRedis() private readonly redis: Redis,
    @Inject(CACHE_MANAGER) private cacheManager: Cache,
    private readonly mailerService: MailerService,
  ) {}

  @Get()
  @Version('1')
  async getHello() {
    // ioredis 原生测试：EX 单位为秒，即 60 秒
    await this.redis.set('token', 'test', 'EX', 60 * 1);
    const res = await this.redis.get('token');

    // Cache-Aside 缓存模式：若缓存存在则直接复用，失效时才计算并重新写入
    // 关键点：cache-manager 与 Keyv 的 TTL 参数单位是毫秒（ms），60 秒需写作 60 * 1000
    let res2 = await this.cacheManager.get<number>('kevin');
    console.log(a);
    if (res2 === undefined || res2 === null) {
      a++;
      await this.cacheManager.set('kevin', a);
      res2 = a;
    }
    
  }

  @Public()
  @Get('health')
  @Version('1')
  healthCheck() {
    return {
    status: 'ok',
    env: 'aws-uat-auto',
    push:'push test',
    timestamp: new Date().toISOString(),
  };
  }

  @Get('sendmail')
  async sendMail(): Promise<any> {
    try {
      const recipient = this.configService.get<string>('MAIL_USER', 'test@example.com');
      await this.mailerService.sendMail({
        to: recipient,
        subject: 'Welcome!',
        template: 'message', // 对应 templates/message.hbs
        context: {
          message: 'This is a test message',
        },
      });

      this.logger.log('邮件发送成功！');
      return {
        message: '发送成功',
      };
    } catch (error) {
      this.logger.error(error);
      return {
        message: '发送失败',
        error: error instanceof Error ? error.message : String(error),
      };
    }
  }
}
