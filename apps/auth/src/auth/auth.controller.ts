import {
  EmailVerificationService,
  Public,
  SignInService,
} from '@nestjs/authentication';
import {
  Body,
  Controller,
  HttpCode,
  Inject,
  Post,
  Req,
  UnauthorizedException,
  UseGuards,
} from '@nestjs/common';
import { AuthService } from './auth.service';
import {
  type SignUpDto,
  type SignInDto,
  signUpSchema,
  signInSchema,
} from './auth.schemas';
import { UserEntity } from '../module/user/user.interface';
import { LocalAuthGuard } from './local-auth.guard';
import requestIp from 'request-ip';
import { hours, minutes, SkipThrottle, Throttle } from '@nestjs/throttler';

@Public()
@Controller('auth')
export class AuthController {
  constructor(
    private readonly authService: AuthService,
    private readonly signInService: SignInService,
    private readonly emailVerificationService: EmailVerificationService,
  ) {}
  //   @UseGuards(LocalAuthGuard)
  @Throttle({
    default: { limit: 30, ttl: minutes(15) },
    account: { limit: 5, ttl: minutes(15) },
  })
  @Post('sign-in')
  @HttpCode(200)
  //   async signIn(@Body({ schema: signInSchema }) body: SignInDto) {
  async signIn(@Body({ schema: signInSchema }) body: SignInDto) {
    //通过 AuthGuard 已经实现了 用户身份的教研，直接获取 authgurad 传回的 req中的值就可以了

    const user = await this.authService.verify(body.email, body.password);
    if (!user) {
      throw new UnauthorizedException('Invalid email or password');
    }
    console.log('user+++++++', user);
    // console.log('UserRoles++++++++++', user.userRoles);
    const permissions = user.userRoles.map((userRole: any) => {
      // console.log('userRole++++++++++', userRole.role.rolePermission);
      return userRole.role.rolePermission.map((rolePermission: any) => {
        return rolePermission.permission;
      });
    });

    console.log('permissions++++++++++', permissions);
    // user.userRoles.map();
    const { accessToken, expiresIn } = await this.authService.login(user);
    console.log('access_token:' + accessToken);
    const { session } = await this.signInService.signIn(String(user.id), {
      method: 'password',
      metadata: {
        // agent: req.headers?.get('user-agent'),
        permissions: permissions,
      },
    });
    return { mfaRequired: session.mfa === 'pending', accessToken, permissions };
  }
  @SkipThrottle({ account: true })
  @Throttle({ default: { limit: 10, ttl: hours(1) } })
  @Post('/signup')
  async signUp(@Body({ schema: signUpSchema }) body: SignUpDto) {
    const user = await this.authService.register(
      body.email,
      body.password,
      body.name,
      body.userRoles,
    );
    await this.signInService.signIn(String(user.id), { method: 'password' });
    await this.emailVerificationService.send({
      id: String(user.id),
      email: user.email,
    });
    return user;
  }
}
