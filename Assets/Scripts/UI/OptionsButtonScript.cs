using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;

public class OptionsButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public RectTransform buttonRectTransform;
    public Button button;
    public Transform canvas;
    public GameObject optionsMenuPrefab;
    public GameObject optionsMenu;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    public void OnPointerEnter(PointerEventData eventData)
    {
        if (canvas == null)
        {
            canvas = GameObject.Find("Canvas").transform;
        }
        Vector3[] buttonCorners = new Vector3[4];
        buttonRectTransform.GetWorldCorners(buttonCorners);
        Vector3 buttonBottomLeftPosition = buttonCorners[0];
        Transform tooltipTransform = canvas.Find("Tooltip");
        if (tooltipTransform != null)
        {
            tooltip = tooltipTransform.gameObject;
        }
        if (tooltip == null)
        {
            tooltip = Instantiate(tooltipPrefab, canvas);
            tooltip.name = "Tooltip";
            tooltip.transform.SetAsLastSibling();
        }
        if (tooltip != null)
        {
            RectTransform tooltipRectTransform = tooltip.GetComponent<RectTransform>();
            tooltipRectTransform.pivot = new Vector2(0, 1f);
            tooltipRectTransform.position = buttonBottomLeftPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
#if UNITY_WEBGL && !UNITY_EDITOR
            StartCoroutine(tooltipScript.SetText("Options [tab]", ""));
#else
            StartCoroutine(tooltipScript.SetText("Options [esc]", ""));
#endif
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayMenuSound(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
        if (canvas == null)
        {
            canvas = GameObject.Find("Canvas").transform;
        }
        if (optionsMenu == null)
        {
            optionsMenu = Instantiate(optionsMenuPrefab, canvas);
        }
        else
        {
            Destroy(optionsMenu);
        }
    }

    void Start()
    {
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        canvas = GameObject.Find("Canvas").transform;
        optionsMenuPrefab = Resources.Load<GameObject>("Prefabs/UI/Options Menu");
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard != null)
        {
#if UNITY_WEBGL && !UNITY_EDITOR
            if (keyboard.tabKey.wasPressedThisFrame)
#else
            if (keyboard.escapeKey.wasPressedThisFrame)
#endif
            {
                OnActivate();
            }
        }
    }
}
