using UnityEngine;
using UnityEngine.InputSystem;

public class TileScript : MonoBehaviour
{
    private InputAction clickAction;
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject highlight;
    public Animator highlightAnimator;
    public bool isOccupied = false;
    private bool isHighlighted = false;
    public bool IsHighlighted 
    {
        get
        {
            return this.isHighlighted;
        }
        set
        {
            this.isHighlighted = value;
            highlightAnimator.SetBool("isHighlighted", isHighlighted);
        }
    }
    private bool isRespawn = false;
    public bool IsRespawn
    {
        get
        {
            return isRespawn;
        }
        set
        {
            if (value == true)
            {
                GameObject respawnOverlay = new GameObject("Respawn Overlay");
                respawnOverlay.transform.parent = this.transform;
                respawnOverlay.transform.localPosition = new Vector3(0, 0, 0);
                SpriteRenderer respawnRenderer = respawnOverlay.AddComponent<SpriteRenderer>();
                respawnRenderer.sortingOrder = 1;
                Sprite respawnSprite = Resources.Load<Sprite>("Respawn");
                respawnRenderer.sprite = respawnSprite;
            }
            isRespawn = value;
        }
    }
    private bool isEnd = false;
    public bool IsEnd
    {
        get
        {
            return isEnd;
        }
        set
        {
            if (value == true)
            {
                GameObject endOverlay = new GameObject("End Overlay");
                endOverlay.transform.parent = this.transform;
                endOverlay.transform.localPosition = new Vector3(0, 0, 0);
                SpriteRenderer endRenderer = endOverlay.AddComponent<SpriteRenderer>();
                endRenderer.sortingOrder = 1;
                Sprite endSprite = Resources.Load<Sprite>("Flag");
                endRenderer.sprite = endSprite;
            }
            isEnd = value;
        }
    }

    void Start()
    {
        var playerInput = FindObjectOfType<PlayerInput>();
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        turnLogic = GameObject.Find("Turn Logic");
        if (turnLogic != null)
        {
            turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        }
        highlight = this.transform.Find("Highlight").gameObject;
        highlightAnimator = highlight.GetComponent<Animator>();
        clickAction = playerInput.actions.FindAction("Click");
        clickAction.performed += OnClick;
    }

    void OnDestroy()
    {
        if (clickAction != null)
        {
            clickAction.performed -= OnClick;
        }
    }

    private void OnClick(InputAction.CallbackContext context)
    {
        Vector2 mousePosition = Camera.main.ScreenToWorldPoint(Mouse.current.position.ReadValue());
        RaycastHit2D hit = Physics2D.Raycast(mousePosition, Vector2.zero);
        if (hit.collider != null)
        {
            if (hit.collider.gameObject == this.gameObject)
            {
                if (!isHighlighted)
                {
                    return;
                }
                switch (turnLogicScript.currentGameState)
                {
                    case TurnLogicScript.GameState.PlayerTurnMove: 
                        playerScript.MoveTo(this.transform.position);
                        turnLogicScript.hasMoved = true;
                        break;
                    case TurnLogicScript.GameState.PlayerTurnAttack:
                        GameObject skillUsed = turnLogicScript.skillUsed;
                        if (skillUsed == null)
                        {
                            return;
                        }
                        Skill skillScript = skillUsed.GetComponent<Skill>();
                        skillScript.UseSkill(this.transform.position, player);
                        break;
                }
            }
        }
    }
}
