import { Injectable } from '@nestjs/common';
import {
  AuthenticationRegistry,
  EmailVerificationHandler,
  type EmailVerificationLink,
} from '@nestjs/authentication';
import { Mailer, type Mailable } from '@nestjs/mail';
import { AuthService } from './auth.service';
import { MailerService } from '@nestjs-modules/mailer';

@Injectable()
export class VerifyEmailMail implements Mailable<EmailVerificationLink> {
  render({ url }: EmailVerificationLink) {
    return {
      subject: 'Confirm your email address',
      template: 'verify-email',
      context: { url },
    };
  }
}

@Injectable()
export class EmailVerificationMailer extends EmailVerificationHandler {
  constructor(
    private readonly authService: AuthService,
    private readonly mailerService: MailerService,
    registry: AuthenticationRegistry,
  ) {
    super();
    registry.registerHandler('emailVerification', this);
  }

  async send(link: EmailVerificationLink) {
    const emailData = new VerifyEmailMail().render(link);
    await this.mailerService.sendMail({
      to: link.email,
      ...emailData,
    });
  }

  // Runs when the link is used. It verifies nothing if the address changed since.
  markVerified(userId: string, email: string) {
    return this.authService.markEmailVerified(userId, email);
  }
}
