import { Injectable } from '@nestjs/common';
import {
  AuthenticationRegistry,
  SessionCookieProvider,
  type SessionRecord,
} from '@nestjs/authentication';
import { UserEntity } from '../module/user/user.interface';
import { UserRepository } from '../module/user/user.repository';

@Injectable()
export class SessionAuth extends SessionCookieProvider<UserEntity> {
  constructor(
    private readonly usersRepository: UserRepository,
    registry: AuthenticationRegistry,
  ) {
    super();
    // Adds this provider to the chain the guard runs for every request.
    registry.registerProvider(this);
  }

  // Called for every request with a live session cookie.
  // Returning null (the user was deleted) ends the session.
  validate(session: SessionRecord) {
    return this.usersRepository.findByIdAuth(Number(session.userId));
  }
}
