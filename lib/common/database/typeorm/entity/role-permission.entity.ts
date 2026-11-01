import {
  Entity,
  JoinColumn,
  ManyToOne,
  PrimaryColumn,
  type Relation,
} from 'typeorm';
import { Role } from './role.entity';
import { Permission } from './permission.entity';

// 使用复合主键的显式中间表，与 UserRole 结构保持一致，便于直接注入 Repository 操作授权关系
@Entity('role_permissions')
export class RolePermission {
  @PrimaryColumn()
  roleId: number;

  @PrimaryColumn()
  permissionId: number;

  // 使用 Relation<T> 包装类型，避免 SWC 生成 design:type 元数据时触发循环依赖的 TDZ 报错
  @ManyToOne(() => Role, (role) => role.rolePermission, {
    onDelete: 'CASCADE',
  })
  @JoinColumn({ name: 'roleId' })
  role: Relation<Role>;

  @ManyToOne(() => Permission, (permission) => permission.rolePermissions, {
    onDelete: 'CASCADE',
  })
  @JoinColumn({ name: 'permissionId' })
  permission: Relation<Permission>;
}
