import {
  Body,
  Controller,
  HttpCode,
  Post,
  UnauthorizedException,
} from '@nestjs/common';
import { Public, TokenService } from '@nestjs/authentication';
import { AuthService } from './auth.service';
import { type SignInDto, signInSchema } from './auth.schemas.js';
import { minutes, Throttle } from '@nestjs/throttler';

@Public()
@Controller('auth/token')
export class TokensController {
  constructor(
    private readonly authService: AuthService,
    private readonly tokenService: TokenService,
  ) {}

  @Throttle({
    default: { limit: 30, ttl: minutes(15) },
    account: { limit: 5, ttl: minutes(15) },
  })
  @Post()
  @HttpCode(200)
  async issue(@Body({ schema: signInSchema }) body: SignInDto) {
    const user = await this.authService.verify(body.email, body.password);
    if (!user) {
      throw new UnauthorizedException('Invalid email or password');
    }
    return this.tokenService.issue(String(user.id), {
      method: 'password',
      // `amr` goes into this access token and into every refreshed one.
      claims: { amr: ['pwd'] },
    });
  }

  
  // An unknown, expired or reused refresh token gets a 401.
  @Post('refresh')
  @HttpCode(200)
  refresh(@Body('refreshToken') refreshToken: string) {
    return this.tokenService.refresh(refreshToken);
  }
}
