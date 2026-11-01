import {
  Column,
  CreateDateColumn,
  Entity,
  JoinColumn,
  ManyToOne,
  OneToMany,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
  type Relation,
} from 'typeorm';
import { User } from './user.entity';
import { OrderItem } from './order-items.entity';

export enum OrderStatus {
  CREATE = 'create',
  PENDING = 'pending',
  ISPAID = 'ispaid',
  DELIVERY = 'delivery',
  SUCCESS = 'success',
  REFUND = 'refund',
}

@Entity('orders')
export class Order {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true, length: 64 })
  orderNo: string;

  @Column()
  userId: number;

  // 使用 Relation 包装类型以规避 SWC 编译时的循环依赖元数据异常
  @ManyToOne(() => User, { onDelete: 'RESTRICT' })
  @JoinColumn({ name: 'userId' })
  user: Relation<User>;

  // 金额使用定点数避免浮点数精度丢失，PostgreSQL 中 decimal 会返回字符串以保证精度
  @Column({ type: 'decimal', precision: 10, scale: 2, default: 0 })
  totalAmount: string;

  @Column({
    type: 'enum',
    enum: OrderStatus,
    default: OrderStatus.CREATE,
  })
  status: OrderStatus;

  @Column({ type: 'varchar', length: 255, nullable: true })
  remark?: string;

  @Column({ type: 'timestamp', nullable: true })
  paidAt?: Date;

  @CreateDateColumn({
    type: 'timestamp',
    default: () => 'CURRENT_TIMESTAMP',
  })
  createdAt: Date;

  @UpdateDateColumn({
    type: 'timestamp',
    default: () => 'CURRENT_TIMESTAMP',
  })
  updatedAt: Date;

  // 开启 cascade 以便在保存订单主表时可在同一事务内自动持久化订单明细
  @OneToMany(() => OrderItem, (item) => item.order, { cascade: true })
  items: Relation<OrderItem[]>;
}

