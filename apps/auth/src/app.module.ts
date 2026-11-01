import { Module } from '@nestjs/common';
import { AppController } from './app.controller';
import { ConfigModule } from '@app/common/config/config.module';

// import { PrismaModule } from './database/prisma/prisma.module';
// import { TypeormModule } from './database/typeorm/typeorm.module';
import { UserModule } from './module/user/user.module';
// import { MongodbModule } from './database/mongodb/mongodb.module';
import { DatabaseModule } from '../../../lib/common/database/database.module';
import { AuthModule } from './auth/auth.module';
import { RoleModule } from './role/role.module';
import { PermissionModule } from './permission/permission.module';
import { PolicyModule } from './policy/policy.module';
import { LogsModule } from '@app/common/logger/logs.module';
import { CacheRedisModule } from '@app/common/cache/cache.redis.module';
import { CacheModule } from '@app/common/cache/cache.module';
import { MailModule } from '@app/common/mail/mail.module';
import { ClientModule } from './client/client.module';

@Module({
  imports: [
    ConfigModule,
    LogsModule,
    CacheRedisModule,
    CacheModule,
    MailModule,
    // PrismaModule,
    // TypeormModule,
    UserModule,
    // MongodbModule,
    DatabaseModule,
    AuthModule,
    RoleModule,
    PermissionModule,
    PolicyModule,
    ClientModule,
  ],
  controllers: [AppController],
  providers: [],
})
export class AppModule {}
