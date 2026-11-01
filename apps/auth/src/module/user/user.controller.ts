import {
  Body,
  Controller,
  Get,
  Post,
  UseGuards,
  Request,
  Inject,
  Param,
} from '@nestjs/common';
import { UserService } from './user.service';
import { CurrentUser } from '@nestjs/authentication';
import { type UserEntity } from './user.interface';
import { User } from '@app/common/database/typeorm/entity/user.entity';
import { ClientProxy } from '@nestjs/microservices';
import { Can } from '@nestjs/authorization';
import { OrderPolicy } from '../../_policy/order.policy';
import { param } from '@app/common/param/param';
import { timeout } from 'rxjs';

@Controller('user')
export class UserController {
  constructor(
    private readonly userService: UserService,
    @Inject('ORDER_SERVICE') private client: ClientProxy,
  ) {}
  //   @UseGuards(JwtAuthGuard)
  // @Permission('find')

  @Get('findall')
  async findAllUser(@Request() req: any): Promise<User[]> {
    // console.log('req+++++++++++++++++++++:', req.user);
    return this.userService.findAllUser();
  }
  //   @Get('findall2')
  //   async findAllUser2(): Promise<User[]> {
  //     return this.userService.findAllUser2();
  //   }

  @Post('create')
  async createUser(@Body() user: User): Promise<User> {
    return this.userService.createUser(user);
  }

  //   @Post('create2')
  //   async createUser2(@Body() user: User): Promise<User> {
  //     return this.userService.createUser2(user);
  //   }

  // @Post('createmongo')
  // async createMongoUser(@Body() user: CreateUserDto) {
  //   return this.userService.insertUser(user);
  // }

  @Get('me')
  me(@CurrentUser() user: UserEntity) {
    return user;
  }

  @Get('checklogin')
  checkLoginUser() {
    return this.userService.findMe();
  }

  @Get('findcustomerorder/:id')
  @Can(OrderPolicy, 'viewOrdersOf', param('id'))
  async findCustomerOrder(@Param('id') id: string) {
    return this.client.send({ cmd: 'findbycustomer' }, id).pipe(timeout(5000));
  }

  //   @Post('createcat')
  //   async createCat(@Body() cat: CreateCatDto) {
  //     return this.userService.createCat(cat);
  //   }

  //   @Get('findcat')
  //   async findCat() {
  //     return this.userService.findMongoCat();
  //   }
}
