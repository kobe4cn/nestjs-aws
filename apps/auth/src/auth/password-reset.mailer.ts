import { Injectable } from '@nestjs/common';
import {
  AuthenticationRegistry,
  PasswordResetHandler,
  type PasswordResetLink,
} from '@nestjs/authentication';
import { Mailer, type Mailable } from '@nestjs/mail';
import { MailerService } from '@nestjs-modules/mailer';
import { AuthService } from './auth.service';

@Injectable()
export class PasswordResetMail implements Mailable<PasswordResetLink> {
  render({ url }: PasswordResetLink) {
    return {
      subject: 'Reset your password',
      template: 'password-reset',
      context: { url },
    };
  }
}

@Injectable()
export class PasswordResetMailer extends PasswordResetHandler {
  constructor(
    private readonly authService: AuthService,
    private readonly mailerService: MailerService,
    registry: AuthenticationRegistry,
  ) {
    super();
    registry.registerHandler('passwordReset', this);
  }

  // The link goes to the address the account has stored, and works only while
  // the account keeps that address and this hash: any change invalidates it.
  async findUser(email: string) {
    const found = await this.authService.findCredentials(email);
    return (
      found && {
        id: String(found.user.id),
        email: found.user.email,
        passwordHash: found.passwordHash,
      }
    );
  }

  async send(link: PasswordResetLink) {
    const resetMail = new PasswordResetMail().render(link);
    await this.mailerService.sendMail({
      to: link.email,
      ...resetMail,
    });
  }

  updatePassword(userId: string, passwordHash: string) {
    return this.authService.updatePasswordHash(Number(userId), passwordHash);
  }
}
