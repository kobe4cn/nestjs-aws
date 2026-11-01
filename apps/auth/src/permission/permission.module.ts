import { Module } from '@nestjs/common';
import { PermissionService } from './permission.service';
import { PermissionController } from './permission.controller';
import { TypeOrmModule } from '@nestjs/typeorm';
import { Permission } from '@app/common/database/typeorm/entity/permission.entity';
import { RolePermission } from '@app/common/database/typeorm/entity/role-permission.entity';

@Module({
  imports: [TypeOrmModule.forFeature([Permission, RolePermission])],
  controllers: [PermissionController],
  providers: [PermissionService],
})
export class PermissionModule {}
