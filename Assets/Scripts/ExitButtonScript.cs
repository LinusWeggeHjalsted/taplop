using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class ExitButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public RectTransform buttonRectTransform;
    public Button button;
    public Transform canvas;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    public void OnPointerEnter(PointerEventData eventData)
    { 
        Vector3[] buttonCorners = new Vector3[4];
        buttonRectTransform.GetWorldCorners(buttonCorners);
        Vector3 buttonBottomRightPosition = buttonCorners[3];
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
            tooltipRectTransform.pivot = new Vector2(1f, 1f);
            tooltipRectTransform.position = buttonBottomRightPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            StartCoroutine(tooltipScript.SetText("Exit mission", ""));
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
        GameObject player = GameObject.Find("Player");
        PlayerDataScript.Instance.BuildDataFromPlayer(player);
#if !UNITY_WEBGL || UNITY_EDITOR
        PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
        if (string.IsNullOrEmpty(PlayerDataScript.Instance.lastHub))
        {
            GameControllerScript.Instance.MainMenu();
        }
        else
        {
            GameControllerScript.Instance.EnterHub(PlayerDataScript.Instance.lastHub);
        }
    }

    void Start()
    {
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        canvas = GameObject.Find("Canvas").transform;
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/Tooltip");
    }
}
