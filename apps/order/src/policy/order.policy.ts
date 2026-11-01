import { Policy, PolicyBefore } from '@nestjs/authorization';
import { Order } from '@app/common/database/typeorm/entity/order.entity';
import { User } from '@app/common/database/typeorm/entity/user.entity';

@Policy()
export class OrderPolicy {
  //implements PolicyBefore<User>
  //   before(
  //     user: User | null,
  //     ability: string,
  //     ...args: any[]
  //   ): boolean | undefined | void | Promise<boolean | undefined | void> {
  //     const rolenames = user?.userRoles?.map((item) => {
  //       return item.role.name;
  //     });

  //     if (rolenames?.includes('admin')) return true;
  //   }

  viewAll(user: User) {
    return user.userRoles
      .map((item) => {
        return item.role.name;
      })
      .includes('admin');
  }

  view(user: User, order: Order) {
    return (
      order.userId === user.id ||
      user.userRoles.some((item) => item.role.name === 'admin')
    );
  }

  refund(user: User, order: Order) {
    return (
      user.userRoles.some((item) => item.role.name === 'admin') &&
      order.status == 'ispaid'
    );
  }
  // Customers list their own orders; staff list anyone's. A guest is denied.
  viewOrdersOf(user: User | null, customerId: string) {
    return (
      !!user &&
      (String(user.id) === customerId ||
        user.userRoles.map((item) => item.role.name).includes('staff'))
    );
  }
}
