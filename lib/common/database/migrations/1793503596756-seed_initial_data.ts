import { MigrationInterface, QueryRunner } from 'typeorm';

export class SeedInitialData1793503596756 implements MigrationInterface {
  name = 'SeedInitialData1793503596756';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // 1. 初始化基础权限 (Permission)
    await queryRunner.query(`
      INSERT INTO "permission" ("id", "name", "controller", "action", "description")
      VALUES
        (1, 'order:read', 'order', 'read', '查看订单权限'),
        (2, 'order:write', 'order', 'write', '管理订单权限'),
        (3, 'user:read', 'user', 'read', '查看用户权限'),
        (4, 'user:write', 'user', 'write', '管理用户权限')
      ON CONFLICT ("name") DO NOTHING;
    `);
    await queryRunner.query(
      `SELECT setval(pg_get_serial_sequence('permission', 'id'), (SELECT COALESCE(MAX("id"), 1) FROM "permission"));`,
    );

    // 2. 初始化角色 (Role)：ID 1 为用户默认角色，ID 2 为管理员角色
    await queryRunner.query(`
      INSERT INTO "role" ("id", "name", "description")
      VALUES
        (1, 'USER', '普通用户角色'),
        (2, 'ADMIN', '超级管理员角色')
      ON CONFLICT ("name") DO NOTHING;
    `);
    await queryRunner.query(
      `SELECT setval(pg_get_serial_sequence('role', 'id'), (SELECT COALESCE(MAX("id"), 1) FROM "role"));`,
    );

    // 3. 为角色关联权限 (RolePermission)
    await queryRunner.query(`
      INSERT INTO "role_permissions" ("roleId", "permissionId")
      VALUES
        (1, 1),
        (2, 1),
        (2, 2),
        (2, 3),
        (2, 4)
      ON CONFLICT DO NOTHING;
    `);

    // 4. 初始化默认管理员用户 (Admin)
    // 密码: 123456789012 (使用 @nestjs/authentication 的 PasswordHasher scrypt 生成)
    const adminPasswordHash =
      '$scrypt$ln=17,r=8,p=1$kR1sq0zKE1HaYIMxnOSHvg$8rreVKKguvmkG2kq/mqNOkNAoiVXLyYOodEL7/KKmEg';
    await queryRunner.query(`
      INSERT INTO "user" ("id", "email", "hashedPassword", "name", "emailVerified")
      VALUES
        (1, 'admin@example.com', '${adminPasswordHash}', 'Admin', true)
      ON CONFLICT ("email") DO UPDATE SET "name" = EXCLUDED."name";
    `);
    await queryRunner.query(
      `SELECT setval(pg_get_serial_sequence('user', 'id'), (SELECT COALESCE(MAX("id"), 1) FROM "user"));`,
    );

    // 5. 为管理员赋予 ADMIN 和 USER 角色
    await queryRunner.query(`
      INSERT INTO "user_role" ("userId", "roleId")
      VALUES
        (1, 1),
        (1, 2)
      ON CONFLICT DO NOTHING;
    `);

    // 6. 初始化测试订单数据 (Order & OrderItem)
    await queryRunner.query(`
      INSERT INTO "orders" ("id", "orderNo", "userId", "totalAmount", "status", "remark", "paidAt")
      VALUES
        (1, 'ORD-20261101-0001', 1, 299.00, 'ispaid', '初始测试付款订单', now()),
        (2, 'ORD-20261101-0002', 1, 99.50, 'create', '初始测试未支付订单', null)
      ON CONFLICT ("orderNo") DO NOTHING;
    `);
    await queryRunner.query(
      `SELECT setval(pg_get_serial_sequence('orders', 'id'), (SELECT COALESCE(MAX("id"), 1) FROM "orders"));`,
    );

    await queryRunner.query(`
      INSERT INTO "order_items" ("id", "orderId", "productId", "productName", "unitPrice", "quantity", "subtotal")
      VALUES
        (1, 1, 101, 'Cloud Server ECS Pod', 199.00, 1, 199.00),
        (2, 1, 102, 'RDS PostgreSQL Storage 20GB', 50.00, 2, 100.00),
        (3, 2, 103, 'ElastiCache Redis Single Node', 99.50, 1, 99.50)
      ON CONFLICT ("id") DO NOTHING;
    `);
    await queryRunner.query(
      `SELECT setval(pg_get_serial_sequence('order_items', 'id'), (SELECT COALESCE(MAX("id"), 1) FROM "order_items"));`,
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM "order_items" WHERE "id" IN (1, 2, 3);`);
    await queryRunner.query(`DELETE FROM "orders" WHERE "orderNo" IN ('ORD-20261101-0001', 'ORD-20261101-0002');`);
    await queryRunner.query(`DELETE FROM "user_role" WHERE "userId" = 1;`);
    await queryRunner.query(`DELETE FROM "user" WHERE "email" = 'admin@example.com';`);
    await queryRunner.query(`DELETE FROM "role_permissions" WHERE "roleId" IN (1, 2);`);
    await queryRunner.query(`DELETE FROM "role" WHERE "name" IN ('USER', 'ADMIN');`);
    await queryRunner.query(`DELETE FROM "permission" WHERE "name" IN ('order:read', 'order:write', 'user:read', 'user:write');`);
  }
}

