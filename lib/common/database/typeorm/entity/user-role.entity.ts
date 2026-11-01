import {
  Entity,
  JoinColumn,
  ManyToOne,
  PrimaryColumn,
  type Relation,
} from 'typeorm';
import { User } from './user.entity';
import { Role } from './role.entity';

// 使用复合主键的显式中间表，便于后续扩展角色分配时间、授权人等审计字段
@Entity()
export class UserRole {
  @PrimaryColumn()
  userId: number;

  @PrimaryColumn()
  roleId: number;

  // 使用 Relation<T> 包装类型，避免 SWC 生成 design:type 元数据时触发循环依赖的 TDZ 报错
  @ManyToOne(() => User, (user) => user.userRoles, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'userId' })
  user: Relation<User>;

  @ManyToOne(() => Role, (role) => role.userRoles, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'roleId' })
  role: Relation<Role>;
}
