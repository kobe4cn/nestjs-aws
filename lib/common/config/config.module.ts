import { Module } from '@nestjs/common';
import { ConfigModule as ConfigModuleBase } from '@nestjs/config';
import z from 'zod';

const envFilePath = ['.env'];

// 使用 Zod passthrough 保留未显式声明的其余环境变量，同时确保核心数据库与运行配置合法
const schema = z
  .object({
    NODE_ENV: z
      .enum(['development', 'production', 'test'])
      .default('development'),
    APP_PORT: z.coerce.number().default(3000),
    SDB_TYPE: z.string().default('postgres'),
    SDB_HOST: z.string().default('localhost'),
    SDB_PORT: z.coerce.number().default(5432),
    SDB_USER: z.string(),
    SDB_PASS: z.string(),
    SDB_DB: z.string(),
  })
  .passthrough();

@Module({
  imports: [
    ConfigModuleBase.forRoot({
      isGlobal: true,
      envFilePath,
      // @nestjs/config 的 validationSchema 仅支持 Joi 接口，使用 Zod 需通过 validate 钩子触发校验
      validate: (config) => schema.parse(config),
    }),
  ],
  providers: [],
})
export class ConfigModule {}
