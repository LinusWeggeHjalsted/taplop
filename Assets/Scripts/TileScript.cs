using UnityEngine;
using UnityEngine.InputSystem;

public class TileScript : MonoBehaviour
{
    private InputAction clickAction;
    public GameObject player;
    public PlayerScript playerScript;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public bool isOccupied = false;
    public bool isHighlighted = false;
    public bool isClickable = false;

    // Start is called once before the first execution of Update after the MonoBehaviour is created
    void Start()
    {
        var playerInput = FindObjectOfType<PlayerInput>();
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerScript>();
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();

        clickAction = playerInput.actions.FindAction("Click");
        clickAction.performed += OnClick;
    }

    private void OnClick(InputAction.CallbackContext context)
    {
        Vector2 mousePosition = Camera.main.ScreenToWorldPoint(Mouse.current.position.ReadValue());
        RaycastHit2D hit = Physics2D.Raycast(mousePosition, Vector2.zero);
        if (hit.collider != null)
        {
            if (hit.collider.gameObject == this.gameObject)
            {
                Debug.Log("clicked tile at " + this.transform.position);
                if (!isClickable)
                {
                    return;
                }
                switch (turnLogicScript.currentGameState)
                {
                    case TurnLogicScript.GameState.PlayerTurnMove: 
                        playerScript.previousPosition = player.transform.position;
                        player.transform.position = this.transform.position;
                        turnLogicScript.hasMoved = true;
                        break;
                    case TurnLogicScript.GameState.PlayerTurnAttack:
                        // to-do
                        break;
                }
            }
        }
    }

    // Update is called once per frame
    void Update()
    {

    }
}
