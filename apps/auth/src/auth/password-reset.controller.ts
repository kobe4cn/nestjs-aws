import {
  BadRequestException,
  Body,
  Controller,
  HttpCode,
  Post,
} from '@nestjs/common';
import { PasswordResetService, Public } from '@nestjs/authentication';
import {
  emailSchema,
  type EmailDto,
  resetPasswordSchema,
  type ResetPasswordDto,
} from './auth.schemas';
import { minutes, Throttle } from '@nestjs/throttler';
import { accountEmail } from './auth.service';

@Public()
@Controller('auth/password')
export class PasswordResetController {
  constructor(private readonly passwordResetService: PasswordResetService) {}

  // The same answer, as fast, whether or not the address has an account:
  // request() returns before it looks the address up.
  @Throttle({
    default: { limit: 10, ttl: minutes(15) },
    // Per address, from any IP address.
    account: { limit: 3, ttl: minutes(15), getTracker: accountEmail },
  })
  @Post('forgot')
  @HttpCode(202)
  forgot(@Body({ schema: emailSchema }) body: EmailDto) {
    this.passwordResetService.request(body.email);
  }

  // Called by the page the link opens, with the token from its URL and the new password.
  @Post('reset')
  @HttpCode(200)
  async reset(@Body({ schema: resetPasswordSchema }) body: ResetPasswordDto) {
    const result = await this.passwordResetService.reset(
      body.token,
      body.password,
      { signIn: true },
    );
    if (!result) {
      throw new BadRequestException('Invalid or expired link');
    }
    return { mfaRequired: result.signedIn?.session.mfa === 'pending' };
  }
}
