import 'reflect-metadata';
import 'dotenv/config';
import { DataSource } from 'typeorm';

import { User } from './typeorm/entity/user.entity';
import { Post } from './typeorm/entity/post.entity';
import { ApiKeyEntity } from './typeorm/entity/api-key.entity';
import { Role } from './typeorm/entity/role.entity';
import { UserRole } from './typeorm/entity/user-role.entity';
import { Permission } from './typeorm/entity/permission.entity';
import { RolePermission } from './typeorm/entity/role-permission.entity';
import { Order } from './typeorm/entity/order.entity';
import { OrderItem } from './typeorm/entity/order-items.entity';

// AWS RDS 默认强制 SSL 连接，允许通过 SDB_SSL 环境变量显式覆盖生产环境的默认 SSL 行为
const sslConfig = process.env.SDB_SSL;
const isProd = process.env.NODE_ENV === 'production';
const enableSsl = sslConfig !== undefined ? sslConfig === 'true' : isProd;

export default new DataSource({
  type: 'postgres',
  host: process.env.SDB_HOST || 'localhost',
  port: Number(process.env.SDB_PORT || 5432),
  username: process.env.SDB_USER || 'crm',
  password: process.env.SDB_PASS || 'crm',
  database: process.env.SDB_DB || 'typeorm_test',
  synchronize: false,
  ssl: enableSsl ? { rejectUnauthorized: false } : false,

  entities: [
    User,
    Post,
    ApiKeyEntity,
    Role,
    UserRole,
    Permission,
    RolePermission,
    Order,
    OrderItem,
  ],
  migrations: [__dirname + '/migrations/**/*{.js,.ts}'],

  // optional
  migrationsRun: false,
  migrationsTableName: 'migrations',
  migrationsTransactionMode: 'all',
});
