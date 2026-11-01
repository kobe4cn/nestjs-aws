import { Injectable } from '@nestjs/common';
import { ApiKeyProvider, AuthenticationRegistry } from '@nestjs/authentication';
import { UserEntity } from '../module/user/user.interface';
import { UserRepository } from '../module/user/user.repository';
import { ApiKeyEntity } from '../../../../lib/common/database/typeorm/entity/api-key.entity';
import { Repository } from 'typeorm';
import { InjectRepository } from '@nestjs/typeorm';

@Injectable()
export class ApiKeyAuth extends ApiKeyProvider<ApiKeyEntity> {
  constructor(
    private readonly userRepository: UserRepository,
    @InjectRepository(ApiKeyEntity)
    private readonly apiKeyRepository: Repository<ApiKeyEntity>,

    registry: AuthenticationRegistry,
  ) {
    // Keys look like cat_<id>_<secret>. The prefix tells secret scanners what they found.
    super({ prefix: 'cat', realm: 'store' });
    // Third in the chain, after SessionAuth and JwtAuth.
    registry.registerProvider(this, { order: 2 });
  }

  // Called with the id part of a key; the provider then checks the hash and the expiry.
  // Returning null (no such key, or its owner was deleted) rejects the key.
  async findKey(id: string) {
    const [key] = await this.apiKeyRepository.find({ where: { id } });
    const user =
      key && (await this.userRepository.findById(Number(key.userId)));
    return user ? { hash: key.hash, user, expiresAt: key.expiresAt } : null;
  }

  async insert(apiEntity: ApiKeyEntity) {
    return this.apiKeyRepository.save(apiEntity);
  }

  async findAll(userId: string) {
    return this.apiKeyRepository.find({
      where: { userId },
      select: {
        id: true,
        createAt: true,
        expiresAt: true,
      },
    });
  }

  async deleteApiKey(userId: string, id: string) {
    return await this.apiKeyRepository.delete({ userId, id });
  }
}
