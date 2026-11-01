import { REQUEST } from '@nestjs/core';
import { UserTypeOrmRepository } from './repository/user.typeorm.repository';
import { Inject, Injectable } from '@nestjs/common';
import type { Request } from 'express';
import { UserRepositoryAbstractClass } from './user-abstract.repository';
import { UserAdapter } from './user.interface';
import { CreateUserDto } from './dto/create-user.dto';

@Injectable()
export class UserRepository implements UserRepositoryAbstractClass {
  constructor(
    // @Inject(REQUEST) private request: Request,
    private userTypeormRepository: UserTypeOrmRepository,
  ) {}
  findByIdAuth(id: number): Promise<any> {
    return this.getRepository().findByIdAuth(id);
  }
  findUserAuthorization(email: string): Promise<any> {
    return this.getRepository().findUserAuthorization(email);
  }
  findById(id: number): Promise<any> {
    return this.getRepository().findById(id);
  }
  findRow(filter: any): Promise<any> {
    return this.getRepository().findRow(filter);
  }
  find(filter?: any): Promise<any[]> {
    return this.getRepository().find(filter);
  }
  create(userObj: any): Promise<any> {
    return this.getRepository().create(userObj);
  }
  update(userObj: any): Promise<any> {
    return this.getRepository().update(userObj);
  }
  delete(id: string): Promise<any> {
    return this.getRepository().delete(id);
  }
  createUserWithRole(createUserDto: CreateUserDto): Promise<any> {
    return this.getRepository().createUserWithRole(createUserDto);
  }

  getRepository(): UserAdapter {
    return this.userTypeormRepository;
  }
}
