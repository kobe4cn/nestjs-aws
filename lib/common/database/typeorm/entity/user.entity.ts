import { Column, Entity, OneToMany, PrimaryGeneratedColumn } from 'typeorm';
import { Post } from './post.entity';
import { UserRole } from './user-role.entity';

@Entity()
export class User {
  @PrimaryGeneratedColumn()
  id: number;
  @Column({ unique: true })
  email: string;
  @Column({ nullable: true })
  hashedPassword?: string;
  @Column({ nullable: true })
  name?: string;
  @Column({
    type: 'timestamp',
    default: () => 'CURRENT_TIMESTAMP',
  })
  createdAt: Date;
  @Column({ default: false })
  emailVerified: boolean;
  @OneToMany(() => Post, (post) => post.author)
  posts: Post[];
  @OneToMany(() => UserRole, (userRole) => userRole.user,{ cascade: true })
  userRoles: UserRole[];
}
