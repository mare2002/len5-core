#ifndef LEN5_H_
#define LEN5_H_

/********************/
/* ---- MACROS ---- */
/********************/

#include <sys/types.h>

/********************/
/* ---- MACROS ---- */
/********************/
/* Peripherals base address */
// Generated len5_memory_map.h supplies these addresses from tb_config_pkg.sv.
// MMAP_MASK must exclude both devices from store-to-load forwarding.
#define PERI_BASE ((unsigned char *) LEN5_SERIAL_ADDR)

/* Serial interface registers */
#define UART_BASE ((unsigned char *) LEN5_SERIAL_ADDR)
#define UART_WRITE_REG (*(UART_BASE + 0x00))
#define UART_WRITE_FLAG (*(UART_BASE + 0x01))
#define UART_READ_REG (*(UART_BASE + 0x02))
#define UART_READ_FLAG (*(UART_BASE + 0x03))

/* Exit code register */
#define EXIT_REG_BASE ((unsigned char *) LEN5_EXIT_ADDR)
#define EXIT_REG (*(EXIT_REG_BASE + 0x00))

/*********************************/
/* ---- FUNCTION PROTOTYPES ---- */
/*********************************/

/**
 * @brief	Minimal serial interface
 *
 * @details	Write the input character to a designated memory location defined
 * in 'serial_write.h'.
 *
 * @param	c: the character to write
 */
void serial_write(char c);

#endif // LEN5_H_
