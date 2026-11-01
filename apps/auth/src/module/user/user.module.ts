import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { UserController } from './user.controller';
import { UserService } from './user.service';

import { UserRepository } from './user.repository';
import { UserTypeOrmRepository } from './repository/user.typeorm.repository';
import { User } from '@app/common/database/typeorm/entity/user.entity';
import { Post } from '@app/common/database/typeorm/entity/post.entity';
import { UserRole } from '@app/common/database/typeorm/entity/user-role.entity';
import { Role } from '@app/common/database/typeorm/entity/role.entity';
import { ClientsModule, Transport } from '@nestjs/microservices';
import { ConfigService } from '@nestjs/config';
import { ConfigEnum } from '@app/common/enum/config.enum';

@Module({
  imports: [
    TypeOrmModule.forFeature([User, Post, UserRole, Role]),
    ClientsModule.registerAsync([
      {
        name: 'ORDER_SERVICE',
        useFactory: async (configService: ConfigService) => ({
          transport: Transport.TCP,
          options: {
            host: configService.get<string>(
              ConfigEnum.ORDER_SERVICE_HOST,
              'localhost',
            ),
            port: Number(
              configService.get<number>(ConfigEnum.ORDER_SERVICE_PORT, 3031),
            ),
          },
        }),
        inject: [ConfigService],
      },
    ]),
  ],
  controllers: [UserController],
  providers: [UserService, UserRepository, UserTypeOrmRepository],
  exports: [UserRepository],
})
export class UserModule {}
