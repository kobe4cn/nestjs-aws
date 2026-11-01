import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  Get,
  HttpCode,
  Post,
  Query,
} from '@nestjs/common';
import {
  CurrentUser,
  EmailVerificationService,
  Public,
} from '@nestjs/authentication';
import type { UserEntity } from '../module/user/user.interface';

@Controller('auth/email')
export class EmailVerificationController {
  constructor(
    private readonly emailVerificationService: EmailVerificationService,
  ) {}

  // Called by the page the link opens, which POSTs the token from its URL.
  @Public()
  @Get('verify')
  @HttpCode(200)
  async verify(@Query('token') token: string) {
    const verified = await this.emailVerificationService.verify(token);
    if (!verified) {
      throw new BadRequestException('Invalid or expired link');
    }
    return { email: verified.email, emailVerified: true };
  }

  // "Send the link again", to the signed-in customer's current address.
  @Post('verification')
  @HttpCode(202)
  async resend(@CurrentUser() user: UserEntity) {
    if (user.emailVerified) {
      throw new ConflictException('Email address already verified');
    }
    await this.emailVerificationService.send({
      id: String(user.id),
      email: user.email,
    });
  }
}
