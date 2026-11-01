import { Module } from '@nestjs/common';
import { AuthController } from './auth.controller';
import { accountEmail, AuthService } from './auth.service';
import { UserModule } from '../module/user/user.module';
import { SessionAuth } from './session-auth.provider';
import { AuthenticationModule } from '@nestjs/authentication';

import { EmailVerificationMailer } from './email-verification.mailer';
import { ConfigService } from '@nestjs/config';
import { EmailVerificationController } from './email-verification.controller';
import { PasswordResetMailer } from './password-reset.mailer';
import { JwtAuth } from './jwt-auth.provider';
import { TokensController } from './tokens.controller';
import { MagicLinkMailer } from './magic-link.mailer';

import { minutes, normalizeIp, ThrottlerModule } from '@nestjs/throttler';
import { ApiKeyEntity } from '../../../../lib/common/database/typeorm/entity/api-key.entity';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ApiKeyAuth } from './api-key-auth.provider';
import { ApiKeysController } from './api-keys.controller';
import { AuthorizationModule } from '@nestjs/authorization';
import { MailModule } from '@app/common/mail/mail.module';
import { ConfigEnum } from '@app/common/enum/config.enum';

@Module({
  imports: [
    TypeOrmModule.forFeature([ApiKeyEntity]),
    UserModule,
    MailModule,
    // PassportModule,
    // JwtModule.registerAsync({
    //   inject: [ConfigService],
    //   useFactory: (config: ConfigService) => ({
    //     secret: config.getOrThrow<string>(ConfigEnum.JWT_SECRET),
    //     signOptions: { expiresIn: '10m' },
    //   }),
    // }),
    ThrottlerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => [
        { name: 'default', ttl: minutes(1), limit: 100 },
        {
          name: 'account',
          ttl: minutes(15),
          limit: 5,
          skipIf: (context) =>
            !accountEmail(context.switchToHttp().getRequest()),
          getTracker: (req) => `${accountEmail(req)}|${normalizeIp(req.ip)}`,
        },
      ],
    }),
    AuthenticationModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => ({
        // 当前测试项目尚未实现自定义持久化 AuthenticationStorage，生产环境需显式允许内存存储以正常启动
        allowInMemoryStorage: true,
        session: {
          absoluteTtl: '14d', // signed out after 14 days, however active
          idleTtl: '3d', // or after 3 days without a request
        },
        emailVerification: {
          url: `${config.getOrThrow<string>(ConfigEnum.APP_URL)}/auth/email/verify`,
        },
        passwordReset: {
          url: `${config.getOrThrow<string>(ConfigEnum.APP_URL)}/reset-password`,
        },
        accessToken: {
          key: config.getOrThrow<string>(ConfigEnum.JWT_SECRET),
          issuer: 'https://api.example.com',
          audience: 'rest-api',
          ttl: '15m',
        },
        magicLink: {
          url: `${config.getOrThrow<string>(ConfigEnum.APP_URL)}/sign-in/magic`,
        },
      }),
    }),
    
  ],
  controllers: [
    AuthController,
    EmailVerificationController,
    TokensController,
    ApiKeysController,
  ],
  providers: [
    AuthService,
    SessionAuth,
    EmailVerificationMailer,
    PasswordResetMailer,
    JwtAuth,
    MagicLinkMailer,
    ApiKeyAuth,
    // LocalStrategy,
    // JwtStrategy,
  ],
})
export class AuthModule {}
