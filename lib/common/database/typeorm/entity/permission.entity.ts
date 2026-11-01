import { Column, Entity, OneToMany, PrimaryGeneratedColumn } from 'typeorm';
import { RolePermission } from './role-permission.entity';

@Entity()
export class Permission {
  @PrimaryGeneratedColumn()
  id: number;

  // 唯一权限标识（如 user:read），用于权限守卫快速比对
  @Column({ unique: true })
  name: string;

  @Column()
  controller: string;

  @Column()
  action: string;

  @Column({ nullable: true })
  description?: string;

  @OneToMany(
    () => RolePermission,
    (rolePermission) => rolePermission.permission,
  )
  rolePermissions: RolePermission[];
}
