import { ForbiddenException, Injectable, ParseIntPipe } from '@nestjs/common';
import {
  AuthenticationRegistry,
  MagicLinkHandler,
  type MagicLink,
} from '@nestjs/authentication';
import { type Mailable } from '@nestjs/mail';
import { AuthService } from './auth.service';
import { MailerService } from '@nestjs-modules/mailer';

@Injectable()
export class MagicLinkMail implements Mailable<MagicLink> {
  render({ url }: MagicLink) {
    return {
      subject: 'Your sign-in link',
      template: 'magic-link',
      context: { url },
    };
  }
}

@Injectable()
export class MagicLinkMailer extends MagicLinkHandler {
  constructor(
    registry: AuthenticationRegistry,
    private readonly authService: AuthService,
    private readonly mailService: MailerService,
  ) {
    super();
    registry.registerHandler('magicLink', this);
  }

  async send(link: MagicLink) {
    const magicLink = new MagicLinkMail().render(link);
    await this.mailService.sendMail({
      to: link.email,
      ...magicLink,
    });
  }

  // Runs when the link is used, which proves the address. The account returned
  // carries its stored `email`, and signs in only if the link went to that address.
  async resolveUser(email: string) {
    const user = await this.authService.findByEmail(email);
    if (!user) {
      // Passwordless sign-up. Return null instead to refuse unknown addresses.
      const row = await this.authService.create(email, true);
      return {
        id: String(row.id),
        email: row.email,
      };
    }
    // A password account whose address nobody confirmed: whoever chose that
    // password may not own the address. Resetting the password proves both.
    if (!user.emailVerified) {
      throw new ForbiddenException('Sign in with your password, or reset it');
    }
    return {
      id: String(user.id),
      email: user.email,
    };
  }
}
