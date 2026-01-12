using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class OverwriteCloneButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public RectTransform buttonRectTransform;
    public Button button;
    public Transform canvas;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    public void OnPointerEnter(PointerEventData eventData)
    {
        // refresh canvas reference if it was destroyed
        if (canvas == null)
        {
            canvas = GameObject.Find("Canvas").transform;
        }
        Vector3[] buttonCorners = new Vector3[4];
        buttonRectTransform.GetWorldCorners(buttonCorners);
        Vector3 buttonTopRightPosition = buttonCorners[2];
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
            tooltipRectTransform.pivot = new Vector2(1f, 0);
            tooltipRectTransform.position = buttonTopRightPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            StartCoroutine(tooltipScript.SetText("Overwrite Clone", ""));
            tooltip.SetActive(true);
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
        SoundControllerScript.Instance.PlayButtonClickSound(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
        PlayerDataScript.CloneData newCloneData = new PlayerDataScript.CloneData();
        newCloneData.totalSalvage = MissionLogicScript.Instance.totalSalvage;
        newCloneData.turnsToComplete = MissionLogicScript.Instance.totalTurns;
        string missionName = MissionLogicScript.Instance.missionName;
        PlayerDataScript.Instance.allCloneData[missionName] = newCloneData;
#if !UNITY_WEBGL || UNITY_EDITOR
        PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
        // to-do - add popup to tell the player the new clone was saved
    }

    void Start()
    {
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        canvas = GameObject.Find("Canvas").transform;
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }
}
