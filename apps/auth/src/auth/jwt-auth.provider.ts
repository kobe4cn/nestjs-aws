import { Injectable } from '@nestjs/common';
import {
  AuthenticationRegistry,
  JwtBearerProvider,
  type JwtClaims,
} from '@nestjs/authentication';
import { UserEntity } from '../module/user/user.interface';
import { AuthService } from './auth.service';

@Injectable()
export class JwtAuth extends JwtBearerProvider<UserEntity> {
  constructor(
    private readonly authService: AuthService,
    registry: AuthenticationRegistry,
  ) {
    // The key, issuer and audience come from the `accessToken` options.
    super({ realm: 'store' });
    // Second in the chain, after SessionAuth (order 0).
    registry.registerProvider(this, { order: 1 });
  }

  // Called after the signature and claims checked out.
  // Returning null (the user was deleted) rejects the token.
  validate({ sub }: JwtClaims) {
    return sub ? this.authService.findById(sub) : null;
  }
}
