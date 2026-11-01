import { Injectable } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { UserRepositoryAbstractClass } from '../user-abstract.repository';
import { User } from '../../../../../../lib/common/database/typeorm/entity/user.entity';
import { Post } from '../../../../../../lib/common/database/typeorm/entity/post.entity';
import { DataSource, In, Repository } from 'typeorm';
import { CreateUserDto } from '../dto/create-user.dto';
import { Role } from '../../../../../../lib/common/database/typeorm/entity/role.entity';

@Injectable()
export class UserTypeOrmRepository implements UserRepositoryAbstractClass {
  constructor(
    @InjectRepository(User)
    private readonly userRepository: Repository<User>,
    @InjectRepository(Post)
    private readonly postRepository: Repository<Post>,
    @InjectRepository(Role)
    private readonly roleRepository: Repository<Role>,
    // @InjectDataSource() private dataSource: DataSource,
  ) {}
  findByIdAuth(id: number): Promise<any> {
    return this.userRepository.findOne({
      where: { id },
      relations: {
        userRoles: {
          role: {
            rolePermission: {
              permission: true,
            },
          },
        },
      },
    });
  }
  async findById(id: number): Promise<any> {
    return this.userRepository.findOneBy({ id });
  }
  async findRow(filter: any): Promise<any> {
    return this.userRepository.findOne({
      where: { email: filter.email },
    });
  }
  async find(filter?: any): Promise<any[]> {
    return this.userRepository.find(filter);
  }
  async create(userObj: any): Promise<any> {
    return this.userRepository.save(userObj);
  }
  async update(userObj: any): Promise<any> {
    return this.userRepository.update(userObj.id, userObj);
  }
  async delete(id: string): Promise<any> {
    return this.userRepository.delete(id);
  }
  async findUserAuthorization(email: string): Promise<any> {
    return this.userRepository.findOne({
      where: { email },
      relations: {
        userRoles: {
          role: {
            rolePermission: {
              permission: true,
            },
          },
        },
      },
    });
  }
  async createUserWithRole(createUserDto: CreateUserDto) {
    const DEFAUT_ROLE_ID = 1;
    const roleIds =
      createUserDto && createUserDto.userRoles
        ? createUserDto.userRoles
        : [DEFAUT_ROLE_ID];
    // const role=await this.roleService.findOne(createUserDto.roleId);
    // const validRoleIds = await this.roleRepository.find({
    //   select: { id: true },
    //   where: { id: In(roleIds) },
    // });

    return await this.userRepository.save({
      ...createUserDto,
      userRoles: roleIds.map((roleId) => ({ roleId })),
    });
  }
}
