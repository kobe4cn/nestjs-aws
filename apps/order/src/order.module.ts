import { Module } from '@nestjs/common';
import { OrderController } from './order.controller';
import { OrderService } from './order.service';
import { ConfigModule } from '@app/common/config/config.module';
import { LogsModule } from '@app/common/logger/logs.module';
import { DatabaseModule } from '@app/common/database/database.module';
import { TypeOrmModule } from '@nestjs/typeorm';
import { Order } from '@app/common/database/typeorm/entity/order.entity';
import { OrderItem } from '@app/common/database/typeorm/entity/order-items.entity';
import { AuthorizationModule } from '@nestjs/authorization';
import { OrderPolicy } from './policy/order.policy';
import { User } from '@app/common/database/typeorm/entity/user.entity';
import { UserRole } from '@app/common/database/typeorm/entity/user-role.entity';
import { RolePermission } from '@app/common/database/typeorm/entity/role-permission.entity';
import { Role } from '@app/common/database/typeorm/entity/role.entity';
import { Permission } from '@app/common/database/typeorm/entity/permission.entity';
import { Post } from '@app/common/database/typeorm/entity/post.entity';

@Module({
  imports: [
    ConfigModule,
    DatabaseModule,
    LogsModule,
    TypeOrmModule.forFeature([
      Order,
      OrderItem,
      User,
      UserRole,
      Role,
      RolePermission,
      Permission,
      Post,
    ]),
    // AuthorizationModule.forRoot({
    //   getUser: (ctx) => ctx.switchToRpc().getData()?.user ?? null,
    // }),
  ],
  controllers: [OrderController],
  providers: [OrderService, OrderPolicy],
})
export class OrderModule {}
