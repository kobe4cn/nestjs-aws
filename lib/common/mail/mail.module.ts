import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { Module } from '@nestjs/common';
import { MailerModule } from '@nestjs-modules/mailer';
import { HandlebarsAdapter } from '@nestjs-modules/mailer/adapters/handlebars.adapter';
import { ConfigService } from '@nestjs/config';
import { ConfigEnum } from '../enum/config.enum';

@Module({
  imports: [
    MailerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => {
        const port = Number(config.get(ConfigEnum.MAIL_PORT, 587));
        // SWC 编译后产物位于 dist/apps/<app>/lib/common/mail，优先查找同级 templates，若不存在则回退至源码目录
        const distTemplateDir = join(__dirname, 'templates');
        const srcTemplateDir = join(
          process.cwd(),
          'lib/common/mail/templates',
        );
        const templateDir = existsSync(distTemplateDir)
          ? distTemplateDir
          : srcTemplateDir;

        return {
          transport: {
            host: config.get(ConfigEnum.MAIL_HOST),
            port,
            // 腾讯 SMTP 465 端口使用隐式 SSL/TLS，587 端口使用 STARTTLS
            secure: port === 465,
            auth: {
              user: config.get(ConfigEnum.MAIL_USER),
              pass: config.get(ConfigEnum.MAIL_PASS),
            },
          },
          defaults: {
            from: config.get(ConfigEnum.MAIL_FROM),
          },
          template: {
            dir: templateDir,
            adapter: new HandlebarsAdapter(),
            options: { strict: true },
          },
        };
      },
    }),
  ],
})
export class MailModule {}
