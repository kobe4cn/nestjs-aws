import {
  Controller,
  Delete,
  Get,
  HttpCode,
  NotFoundException,
  Param,
  Post,
  SerializeOptions,
  StandardSchemaSerializerInterceptor,
  UseInterceptors,
} from '@nestjs/common';
import { Authenticate, CurrentUser } from '@nestjs/authentication';
import { ApiKeyAuth } from './api-key-auth.provider.js';
import { SessionAuth } from './session-auth.provider.js';
import { apiKeysSchemas } from './api-key-schemas.js';

const ONE_YEAR = 365 * 24 * 60 * 60 * 1000;

// Managed from the web app, signed in with a session: a key can't create or revoke keys.
@Authenticate({ providers: [SessionAuth] })
@UseInterceptors(StandardSchemaSerializerInterceptor)
@Controller('auth/api-keys')
export class ApiKeysController {
  constructor(private readonly apiKeyAuth: ApiKeyAuth) {}

  // The only response that contains the key: the table keeps its hash.
  //   @UseInterceptors(ApikeyInterceptor)

  @Post()
  @SerializeOptions({ schema: apiKeysSchemas })
  async create(@CurrentUser('id') userId: number) {
    const { key, id, hash } = this.apiKeyAuth.generate();
    const createAt = new Date();
    const expiresAt = new Date(createAt.getTime() + ONE_YEAR);
    return this.apiKeyAuth.insert({
      id,
      userId: String(userId),
      hash,
      createAt,
      expiresAt,
    });

    // return {
    //   id: apiEntity.id,
    //   key,
    //   createdAt: apiEntity.createAt,
    //   expiresAt: apiEntity.expiresAt,
    // };
    // return {
    //   ...apiEntity,
    //   key: key,
    // };
  }

  @Get()
  list(@CurrentUser('id') userId: string) {
    // return this.db
    //   .select({
    //     id: apiKeys.id,
    //     createdAt: apiKeys.createdAt,
    //     expiresAt: apiKeys.expiresAt,
    //   })
    //   .from(apiKeys)
    //   .where(eq(apiKeys.userId, userId));
    return this.apiKeyAuth.findAll(userId);
  }

  // Revoked from the next request on. Another customer's key is a 404.
  @Delete(':id')
  @HttpCode(204)
  async revoke(@CurrentUser('id') userId: string, @Param('id') id: string) {
    // const revoked = await this.db
    //   .delete(apiKeys)
    //   .where(and(eq(apiKeys.id, id), eq(apiKeys.userId, userId)))
    //   .returning();
    const { raw, affected } = await this.apiKeyAuth.deleteApiKey(userId, id);
    if (affected === 0) {
      throw new NotFoundException();
    }
  }
}
