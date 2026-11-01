import { Controller, Get } from '@nestjs/common';
import { OrderService } from './order.service';
import { Can } from '@nestjs/authorization';
import { MessagePattern, Payload } from '@nestjs/microservices';
import { User } from '@app/common/database/typeorm/entity/user.entity';
import { OrderPolicy } from './policy/order.policy';
import { param } from '@app/common/param/param';

@Controller()
export class OrderController {
  constructor(private readonly orderService: OrderService) {}

  @MessagePattern({ cmd: 'findall' })
  // @Can.Anyone()
  async findAll(user: User) {
    return this.orderService.findAll(user);
  }

  @MessagePattern({ cmd: 'findone' })
  // @Can.Anyone()
  async findOne(@Payload() data: { user: User; id: string }) {
    return this.orderService.findOne(data.user, data.id);
  }

  // @MessagePattern({ cmd: 'refund' })
  // @Can.Anyone()
  // async refund(@Payload() data: { user: User; id: string }) {
  //   return this.orderService.refund(data.user, data.id);
  // }

  @MessagePattern({ cmd: 'findbycustomer' })
  // @Can(OrderPolicy, 'viewOrdersOf', (ctx) => [
  //   ctx.switchToRpc().getData().customerId,
  // ])
  async findByCustomer(@Payload() customerId: string) {
    return this.orderService.findByCustomer(customerId);
  }
}
