import { Injectable } from '@nestjs/common';
import { TypeOrmModuleOptions, TypeOrmOptionsFactory } from '@nestjs/typeorm';
import { ConfigService } from '@nestjs/config';
import { ConfigEnum } from '../../enum/config.enum';

@Injectable()
export class TypeOrmConfigService implements TypeOrmOptionsFactory {
  constructor(private readonly configService: ConfigService) {}
  createTypeOrmOptions(
    connectionName?: string,
  ): Promise<TypeOrmModuleOptions> | TypeOrmModuleOptions {
    // const tenantId = this.request.headers['x-tenant-id'];

    // AWS RDS PostgreSQL 15+ 默认强制开启 SSL 连接，支持通过 SDB_SSL 显式控制或在生产环境默认启用
    const sslConfig = this.configService.get<string>(ConfigEnum.SDB_SSL);
    const isProd =
      this.configService.get<string>(ConfigEnum.NODE_ENV) === 'production';
    const enableSsl =
      sslConfig !== undefined ? sslConfig === 'true' : isProd;

    const envConfig = {
      type: this.configService.get(ConfigEnum.SDB_TYPE, 'postgres') as 'postgres',
      host: this.configService.get<string>(ConfigEnum.SDB_HOST, 'localhost'),
      port: Number(this.configService.get(ConfigEnum.SDB_PORT, 5432)),
      username: this.configService.get<string>(ConfigEnum.SDB_USER),
      password: this.configService.get<string>(ConfigEnum.SDB_PASS),
      autoLoadEntities:
        String(this.configService.get(ConfigEnum.SDB_AUTOLOAD, 'true')) ===
        'true',
      synchronize: false,
      ssl: enableSsl ? { rejectUnauthorized: false } : false,
      //   tenantId,
      retryAttempts: 10,
      retryDelay: 5000,
    };
    let config = {
      database: this.configService.get<string>(ConfigEnum.SDB_DB),
    };
    // if (tenantId === '2') {
    //   config = {
    //     database: 'typeormtest2',
    //   };
    // }
    const finalConfig = Object.assign(envConfig, config);
    return finalConfig;
  }
}
