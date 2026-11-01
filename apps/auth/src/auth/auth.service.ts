import { ConflictException, Inject, Injectable } from '@nestjs/common';
import { UserRepository } from '../module/user/user.repository';
import { type UserEntity } from '../module/user/user.interface';
import { PasswordHasher, TokenService } from '@nestjs/authentication';

@Injectable()
export class AuthService {
  constructor(
    private readonly userRepository: UserRepository,
    private readonly passwordHasher: PasswordHasher,
    private readonly tokenService: TokenService,
    // private jwtService: JwtService,
  ) {}

  async findCredentials(
    email: string,
  ): Promise<{ user: any; passwordHash: string | null } | null> {
    const row = await this.userRepository.findUserAuthorization(email);
    return row ? { user: row as any, passwordHash: row.hashedPassword } : null;
  }

  async updatePasswordHash(id: number, hashedPassword: string): Promise<void> {
    const row = await this.userRepository.update({ id, hashedPassword });
    console.log(row);
  }
  async register(
    email: string,
    password: string,
    name: string,
    userRoles?: number[],
  ): Promise<UserEntity> {
    if (await this.userRepository.findRow({ email })) {
      throw new ConflictException('Email already registered');
    }
    // The address is unverified: anyone can type any email into a sign-up form.
    return this.userRepository.createUserWithRole({
      email,
      hashedPassword: await this.passwordHasher.hash(password),
      name,
      userRoles: userRoles || [1],
    });
  }

  /** The user, or `null` when the email or the password is wrong. */
  async verify(email: string, password: string): Promise<any | null> {
    const found = await this.findCredentials(email);
    // With no account (or no password), verify() checks a dummy hash, so the
    // response time does not reveal which emails are registered.
    const valid = await this.passwordHasher.verify(
      password,
      found?.passwordHash,
    );
    if (!valid || !found?.passwordHash) {
      return null;
    }
    // The cost settings changed since this hash was stored: upgrade it now,
    // while we have the plaintext.
    if (this.passwordHasher.needsRehash(found.passwordHash)) {
      await this.updatePasswordHash(
        found.user.id,
        await this.passwordHasher.hash(password),
      );
    }
    return found.user;
  }
  async markEmailVerified(id: string, email: string): Promise<boolean> {
    const row = await this.userRepository.update({
      id,
      emailVerified: true,
    });
    return row.affected > 0;
  }

  async findById(id: string): Promise<UserEntity> {
    const row = await this.userRepository.findById(Number(id));
    return row;
  }

  async findByEmail(email: string): Promise<UserEntity> {
    return this.userRepository.findRow({ email });
  }

  async create(email: string, emailVerified: boolean): Promise<UserEntity> {
    return this.userRepository.create({ email, emailVerified });
  }

  async login(user: any) {
    // const payload = {
    //   username: user.email,
    //   sub: String(user.id),
    //   iss: 'https://api.example.com',
    //   aud: 'rest-api',
    // };
    // return {
    //   access_token: this.jwtService.sign(payload),
    // };
    const payload = {
      method: 'password',
      claims: { amr: ['pwd'], username: user.email },
    };
    return await this.tokenService.issue(String(user.id), payload);
  }
}

export function accountEmail(req: { body?: { email?: unknown } }) {
  const email = req.body?.email;
  return typeof email === 'string'
    ? email.trim().normalize('NFC').toLowerCase()
    : '';
}
