-----------------------------------
-- ВОССТАНОВЛЕНИЕ ДАННЫХ ТАБЛИЦЫ --
-----------------------------------
--Максимальное время хранения данных для восстановления в минутах (по умолчанию 1440 мин = 24 часа)
select * from V$PARAMETER where name = 'db_flashback_retention_target';
--Просмотр текущей мметки SCN
select dbms_flashback.get_system_change_number from dual;
--Запрос данных на заданный момент времени
select *
from t as of scn :scn;
--или
select * 
from t as of timestamp to_timestamp('2017-08-28 01:00:00', 'YYYY-MM-DD HH:MI:SS');
--Восстановление
--1. разрешение на перемещение строк в БД
alter table t enable row movement;
--2. восстановление состояния таблицы к метке scn
flashback table t to scn :scn;

-----------------
-- ПАРАЛЛЕЛИЗМ --
-----------------
--SID текущего сеанса
select sid from v$mystat where rownum = 1;
--или
select sys_context('userenv','sid') from dual;

--Проверка активации PDML (параллельное выполнение операции DML - INSERT, UPDATE, DELETE. MERGE)
select pdml_enabled from v$session where sid= sys_context('userenv','sid');

--Список параллельных сессий м транзакций
select a.sid, a.program, b.start_time, b.used_ublk,
b.xidusn ||'.'|| b.xidslot || '.' || b.xidsqn trans_id
from v$session a, v$transaction b
where a.taddr = b.addr
and a.sid in ( select sid
from v$px_session
where qcsid = 258)
order by sid;

--Тип и количество параллельных действий
select name, value from v$statname a, v$mystat b
where a.statistic# = b.statistic# and name like '%parallel%';
