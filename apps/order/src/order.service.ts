import { Order } from '@app/common/database/typeorm/entity/order.entity';
import { AuthorizationService } from '@nestjs/authorization';
import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { OrderPolicy } from './policy/order.policy';
import { User } from '@app/common/database/typeorm/entity/user.entity';
import { MessagePattern } from '@nestjs/microservices';

@Injectable()
export class OrderService {
  constructor(
    @InjectRepository(Order) private orderRepo: Repository<Order>,
    // private readonly authorizationService: AuthorizationService,
  ) {}
  async findAll(user: User): Promise<Order[]> {
    // return (await this.authorizationService.can(OrderPolicy, 'viewAll', user))
    //   ? this.orderRepo.find()
    //   : this.orderRepo.find({ where: { userId: user.id } });
    return this.orderRepo.find({ where: { userId: user.id } });
  }

  async findOne(user: User, id: string) {
    const order = await this.orderRepo.findOne({ where: { id: Number(id) } });
    if (!order) {
      throw new Error('Order not found');
    }
    // await this.authorizationService.authorize(OrderPolicy, 'view', user, order);
    return order;
  }

  @MessagePattern({ cmd: 'findbycustomer' })
  async findByCustomer(customerId: string) {
    // await this.authorizationService.authorize(
    //   OrderPolicy,
    //   'viewOrdersOf',
    //   user,
    //   customerId,
    // );
    return this.orderRepo.find({ where: { userId: Number(customerId) } });
  }
}
