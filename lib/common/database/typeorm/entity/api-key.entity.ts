import { text } from 'stream/consumers';
import {
  Column,
  Entity,
  Index,
  PrimaryColumn,
  PrimaryGeneratedColumn,
} from 'typeorm';

@Entity('api_keys')
@Index('api_keys_user_id_idx', ['userId'])
export class ApiKeyEntity {
  @PrimaryColumn({ type: 'text' })
  id: string;
  @Column({ type: 'text', name: 'user_id' })
  userId: string;
  @Column({ type: 'text' })
  hash: string;
  @Column({ type: 'timestamptz', name: 'create_at' })
  createAt: Date;
  @Column({ type: 'timestamptz', name: 'expires_at' })
  expiresAt: Date;
}
